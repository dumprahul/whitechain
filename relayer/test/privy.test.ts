import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { getAddress } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { authorizationPublicKey, toJsonTypedData } from "../src/privy/signer.js";
import { buildTypedData } from "../src/chain/typedData.js";
import { bootstrap, U, type E2E } from "./helpers/e2e.js";

let e: E2E;
const PLATFORM = "platform-secret-key-123";
const oneClick = (rid: string, approver: string) => e.api("POST", `/v1/requests/${rid}/one-click-approval`, { approver });

beforeAll(async () => {
  // five ops team members, each with their own (stand-in) Privy wallet; budgets and tiers are the defaults
  e = await bootstrap({ privy: { approvers: 5 } });
});
afterAll(async () => e?.stop());

describe("approver wallets", () => {
  it("are created for the platform only, and listed", async () => {
    expect((await e.app.inject({ method: "POST", url: "/v1/approver-wallets", payload: { label: "x" } })).statusCode).toBe(401);
    const list = await e.app.inject({ method: "GET", url: "/v1/approver-wallets", headers: { "x-api-key": PLATFORM } });
    expect(list.json().map((w: any) => w.address)).toEqual(e.privy!.addresses);
    expect(JSON.stringify(list.json())).not.toContain("wallet_"); // Privy wallet ids are not exposed
  });

  it("are the approvers the vault registered", async () => {
    for (const a of e.privy!.addresses) expect(await e.ctx.reader.isApprover(e.vault, a)).toBe(true);
  });
});

describe("one-click approval", () => {
  it("pays a small invoice: Privy signs, the vault verifies, funds move", async () => {
    const created = await e.api("POST", `/v1/orgs/${e.vault}/payments`, { payee: e.vendor, amount: String(250n * U), ref: "INV-privy" });
    expect(created.body.required).toBe(1);
    const before = await e.balance(e.vendor);
    const r = await oneClick(created.body.id, e.privy!.addresses[0]!);
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    expect(r.body.approvals[0].channel).toBe("one-click");
    await e.waitStatus(created.body.id, "CONFIRMED");
    expect(await e.balance(e.vendor)).toBe(before + 250n * U);
    expect(e.privy!.signer.signed).toContain("Payment");
  });

  it("refuses a second click by the same person", async () => {
    const created = await e.api("POST", `/v1/orgs/${e.vault}/payments`, { payee: e.vendor, amount: String(5n * U) });
    await oneClick(created.body.id, e.privy!.addresses[1]!);
    await e.waitStatus(created.body.id, "CONFIRMED");
    const again = await oneClick(created.body.id, e.privy!.addresses[1]!);
    expect(again.status).toBe(409);
  });

  it("refuses amounts above the one-click limit", async () => {
    const created = await e.api("POST", `/v1/orgs/${e.vault}/payments`, { payee: e.vendor, amount: String(1_000n * U) });
    expect(created.body.required).toBe(3);
    const r = await oneClick(created.body.id, e.privy!.addresses[0]!);
    expect(r.status).toBe(403);
    expect(r.body.error?.code ?? r.body.code).toBe("ONE_CLICK_NOT_ALLOWED");
    expect((await e.api("GET", `/v1/requests/${created.body.id}`)).body.approvals).toHaveLength(0);
  });

  it("refuses governance changes, which need a stronger sign-in", async () => {
    const created = await e.api("POST", `/v1/orgs/${e.vault}/payees`, { action: "add", address: e.employee });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    const r = await oneClick(created.body.id, e.privy!.addresses[0]!);
    expect(r.status).toBe(403);
  });

  it("refuses a wallet this relayer does not manage, and unknown requests", async () => {
    const created = await e.api("POST", `/v1/orgs/${e.vault}/payments`, { payee: e.vendor, amount: String(5n * U) });
    expect((await oneClick(created.body.id, privateKeyToAccount(generatePrivateKey()).address)).status).toBe(404);
    expect((await oneClick("does-not-exist", e.privy!.addresses[0]!)).status).toBe(404);
    await e.api("POST", `/v1/requests/${created.body.id}/cancel`);
  });

  it("refuses a managed wallet that is not an approver of this vault", async () => {
    const outsider = await e.app.inject({ method: "POST", url: "/v1/approver-wallets", payload: { label: "outsider" }, headers: { "x-api-key": PLATFORM } });
    const created = await e.api("POST", `/v1/orgs/${e.vault}/payments`, { payee: e.vendor, amount: String(5n * U) });
    const r = await oneClick(created.body.id, outsider.json().address);
    expect(r.status).toBe(403);
    expect(r.body.error?.code ?? r.body.code).toBe("NOT_APPROVER");
    await e.api("POST", `/v1/requests/${created.body.id}/cancel`);
  });

  it("needs the business's own API key", async () => {
    const created = await e.api("POST", `/v1/orgs/${e.vault}/payments`, { payee: e.vendor, amount: String(5n * U) });
    const r = await e.app.inject({ method: "POST", url: `/v1/requests/${created.body.id}/one-click-approval`, payload: { approver: e.privy!.addresses[0] } });
    expect(r.statusCode).toBe(401);
    await e.api("POST", `/v1/requests/${created.body.id}/cancel`);
  });

  it("mixes with signatures from other channels: a 3-approval payment with Privy wallets signing through the API path", async () => {
    // above the one-click limit the same wallets can still approve, but only by a signature the caller supplies
    const created = await e.api("POST", `/v1/orgs/${e.vault}/payments`, { payee: e.vendor, amount: String(1_500n * U) });
    for (let i = 0; i < 3; i++) {
      const addr = e.privy!.addresses[i]!;
      const wallet = [...e.privy!.signer.wallets.values()].find((w) => w.address === addr)!;
      const td = (await e.api("GET", `/v1/requests/${created.body.id}`)).body.typedData;
      const message = { ...td.message };
      for (const f of td.types.Payment) if (f.type.startsWith("uint")) message[f.name] = BigInt(message[f.name]);
      const signature = await wallet.signTypedData({ domain: td.domain, types: td.types, primaryType: td.primaryType, message } as any);
      expect((await e.api("POST", `/v1/requests/${created.body.id}/approvals`, { signer: addr, signature })).status).toBe(201);
    }
    await e.waitStatus(created.body.id, "CONFIRMED");
  });
});

describe("one-click limit with a single approver", () => {
  it("still caps the amount even when the tiers would only ask for one approval", async () => {
    // with a lowered limit, a payment that needs one approval is refused once it exceeds the cap
    const prev = e.ctx.config.PRIVY_ONE_CLICK_MAX;
    (e.ctx.config as any).PRIVY_ONE_CLICK_MAX = 10n * U;
    try {
      const small = await e.api("POST", `/v1/orgs/${e.vault}/payments`, { payee: e.vendor, amount: String(10n * U) });
      const big = await e.api("POST", `/v1/orgs/${e.vault}/payments`, { payee: e.vendor, amount: String(11n * U) });
      expect(big.body.required).toBe(1);
      expect((await oneClick(big.body.id, e.privy!.addresses[2]!)).status).toBe(403);
      expect((await oneClick(small.body.id, e.privy!.addresses[2]!)).status).toBe(201);
      await e.waitStatus(small.body.id, "CONFIRMED");
      await e.api("POST", `/v1/requests/${big.body.id}/cancel`);
    } finally {
      (e.ctx.config as any).PRIVY_ONE_CLICK_MAX = prev;
    }
  });
});

describe("helpers", () => {
  it("toJsonTypedData keeps every field and turns bigints into strings", () => {
    const td = buildTypedData(1874, "0x000000000000000000000000000000000000dEaD", "Payment", {
      kind: 0, payee: "0x000000000000000000000000000000000000bEEF", amount: 2n ** 200n, budgetId: "0x" + "11".repeat(32), ref: "0x" + "22".repeat(32), nonce: 7n, validBefore: 1893456000n,
    });
    const j = toJsonTypedData(td);
    expect(j.primary_type).toBe("Payment");
    expect(j.message.amount).toBe((2n ** 200n).toString());
    expect(j.domain.chainId).toBe(1874);
    expect(JSON.parse(JSON.stringify(j))).toEqual(j);
    expect(j.types.Payment).toHaveLength(7);
  });

  it("derives the P-256 public key Privy expects from a PKCS8 private key", async () => {
    const { generateKeyPairSync } = await import("node:crypto");
    const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
    const priv = privateKey.export({ format: "der", type: "pkcs8" }).toString("base64");
    const pub = publicKey.export({ format: "der", type: "spki" }).toString("base64");
    expect(authorizationPublicKey(priv)).toBe(pub);
  });

  it("Privy endpoints answer 501 when Privy is not configured", async () => {
    const plain = await bootstrap();
    try {
      const r = await plain.app.inject({ method: "POST", url: "/v1/approver-wallets", payload: { label: "x" }, headers: { "x-api-key": PLATFORM } });
      expect(r.statusCode).toBe(501);
    } finally {
      await plain.stop();
    }
  });
});

describe("quorum payments with one-click (2 of 3)", () => {
  let q: E2E;
  beforeAll(async () => {
    const MAX = String((1n << 128n) - 1n);
    q = await bootstrap({
      privy: { approvers: 3 },
      tiers: [{ maxAmount: MAX, approvals: 2 }],
      config: { PRIVY_ONE_CLICK_MAX_APPROVALS: "2", PRIVY_ONE_CLICK_MAX: String(10_000n * U) },
    });
  });
  afterAll(async () => q?.stop());
  const click = (rid: string, who: string) => q.api("POST", `/v1/requests/${rid}/one-click-approval`, { approver: who });

  it("pays only after two different members have clicked", async () => {
    const [a, b, c] = q.privy!.addresses;
    const created = await q.api("POST", `/v1/orgs/${q.vault}/payments`, { payee: q.vendor, amount: String(300n * U) });
    expect(created.body.required).toBe(2);
    const before = await q.balance(q.vendor);

    expect((await click(created.body.id, a!)).status).toBe(201);
    expect((await q.api("GET", `/v1/requests/${created.body.id}`)).body.status).toBe("PENDING_APPROVAL");
    expect(await q.balance(q.vendor)).toBe(before); // one of two: nothing moved

    expect((await click(created.body.id, a!)).status).toBe(409); // the same person cannot count twice
    expect((await click(created.body.id, b!)).status).toBe(201);
    await q.waitStatus(created.body.id, "CONFIRMED");
    expect(await q.balance(q.vendor)).toBe(before + 300n * U);

    // the third member's late click is refused: the request is already paid
    expect((await click(created.body.id, c!)).status).toBe(409);
  });

  it("still refuses requests that need more approvals than the setting allows", async () => {
    (q.ctx.config as any).PRIVY_ONE_CLICK_MAX_APPROVALS = 1;
    try {
      const created = await q.api("POST", `/v1/orgs/${q.vault}/payments`, { payee: q.vendor, amount: String(5n * U) });
      expect((await click(created.body.id, q.privy!.addresses[0]!)).status).toBe(403);
      await q.api("POST", `/v1/requests/${created.body.id}/cancel`);
    } finally {
      (q.ctx.config as any).PRIVY_ONE_CLICK_MAX_APPROVALS = 2;
    }
  });

  it("still enforces the amount cap on quorum payments", async () => {
    const created = await q.api("POST", `/v1/orgs/${q.vault}/payments`, { payee: q.vendor, amount: String(20_000n * U) });
    expect((await click(created.body.id, q.privy!.addresses[0]!)).status).toBe(403);
    await q.api("POST", `/v1/requests/${created.body.id}/cancel`);
  });
});
