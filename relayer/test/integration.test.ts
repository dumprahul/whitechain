import { createPublicClient, createTestClient, http, parseAbi, type Address, type Hex } from "viem";
import type { FastifyInstance } from "fastify";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts";
import { buildApp } from "../src/api/server.js";
import { NotAllowedError } from "../src/chain/allowlist.js";
import { orgVaultAbi } from "../src/chain/abis.js";
import { loadConfig } from "../src/config.js";
import { createContext, type Context } from "../src/context.js";
import {
  deployAll,
  hydrateAuthTypedData,
  hydrateVaultTypedData,
  mintUsdt,
  newAccount,
  startAnvil,
  type Chain,
  type Deployment,
} from "./helpers/harness.js";

const U = 1_000_000n;
const erc20 = parseAbi(["function balanceOf(address) view returns (uint256)"]);

let chain: Chain;
let dep: Deployment;
let ctx: Context;
let app: FastifyInstance;
let pc: ReturnType<typeof createPublicClient>;
let testClient: ReturnType<typeof createTestClient>;

const approverKeys = Array.from({ length: 5 }, () => generatePrivateKey());
const approvers = approverKeys.map((k) => privateKeyToAccount(k));
const payer = newAccount();
const treasurer = newAccount();
const vendor = newAccount().address;
const employee = newAccount().address;
const outsider = newAccount();

let vault: Address;
let apiKey: string;

const H = (key = apiKey, extra: Record<string, string> = {}) => ({ "x-api-key": key, ...extra });

async function api(method: "GET" | "POST" | "DELETE", url: string, body?: unknown, headers: Record<string, string> = H()) {
  const res = await app.inject({ method, url, payload: body as any, headers });
  return { status: res.statusCode, body: res.json() as any, raw: res };
}

const balance = async (who: Address) => (await pc.readContract({ address: dep.usdt, abi: erc20, functionName: "balanceOf", args: [who] })) as bigint;

async function sign(request: any, account = approvers[0]!) {
  const td = hydrateVaultTypedData(request.typedData);
  return account.signTypedData(td as any);
}

async function approve(rid: string, by: number | ReturnType<typeof newAccount>) {
  const acct = typeof by === "number" ? approvers[by]! : by;
  const r = await api("GET", `/v1/requests/${rid}`);
  const signature = await sign(r.body, acct as any);
  return api("POST", `/v1/requests/${rid}/approvals`, { signer: acct.address, signature });
}

async function waitStatus(rid: string, want: string, timeoutMs = 30_000) {
  const start = Date.now();
  for (;;) {
    const r = await api("GET", `/v1/requests/${rid}`);
    if (r.body.status === want) return r.body;
    if (["FAILED", "REJECTED", "EXPIRED", "CANCELLED"].includes(r.body.status) && r.body.status !== want) {
      throw new Error(`request ${rid} ended as ${r.body.status}: ${r.body.error}`);
    }
    if (Date.now() - start > timeoutMs) throw new Error(`timeout waiting for ${want}; at ${r.body.status} (${r.body.error})`);
    await new Promise((res) => setTimeout(res, 100));
  }
}

/** Create a request, collect `n` approvals, wait for confirmation. */
async function runThrough(path: string, body: unknown, n: number, startAt = 0, method: "POST" | "DELETE" = "POST") {
  const created = await api(method, path, body);
  expect(created.status, JSON.stringify(created.body)).toBe(201);
  expect(created.body.required).toBe(n);
  let last;
  for (let i = 0; i < n; i++) last = await approve(created.body.id, startAt + i);
  expect(last!.status).toBe(201);
  const done = await waitStatus(created.body.id, "CONFIRMED");
  return done;
}

beforeAll(async () => {
  chain = await startAnvil();
  dep = await deployAll(chain.rpc);
  pc = createPublicClient({ transport: http(chain.rpc) });
  testClient = createTestClient({ mode: "anvil", transport: http(chain.rpc) });

  await mintUsdt(chain.rpc, dep.usdt, payer.address, 100n * U);
  await mintUsdt(chain.rpc, dep.usdt, treasurer.address, 10_000_000n * U);

  const config = loadConfig({
    CHAIN_ID: "31337",
    RPC_URL: chain.rpc,
    USDT_ADDRESS: dep.usdt,
    FACTORY_ADDRESS: dep.factory,
    RELAYER_PRIVATE_KEY: dep.relayerKey,
    CONFIRMATIONS: "0",
    POLLING_INTERVAL_MS: "50",
    REQUEST_TTL_SECONDS: "86400",
    PLATFORM_API_KEY: "platform-secret-key-123",
    RATE_LIMIT_PER_MINUTE: "1000",
  });
  ctx = createContext(config);
  app = buildApp(ctx);
  await app.ready();
});

afterAll(async () => {
  ctx?.submitter.stop();
  await app?.close();
  chain?.stop();
});

describe("business creation", () => {
  const platform = { "x-api-key": "platform-secret-key-123" };
  let prepared: any;

  it("requires the platform key", async () => {
    const r = await api("POST", "/v1/orgs/prepare", {}, {});
    expect(r.status).toBe(401);
  });

  it("prepares the EIP-3009 authorization bound to the parameters", async () => {
    const r = await api(
      "POST",
      "/v1/orgs/prepare",
      {
        payer: payer.address,
        init: {
          approvers: approvers.map((a) => a.address),
          budgets: [
            { id: "GENERAL", limit: String(100_000n * U), periodMonths: 1 },
            { id: "COMPENSATION", limit: String(1_000_000n * U), periodMonths: 0 },
          ],
          sweep: { enabled: true, minLiquid: String(10_000n * U), maxInYield: String(500_000n * U) },
          payees: [vendor, employee],
        },
      },
      platform,
    );
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(r.body.fee).toBe(String(5n * U));
    expect(r.body.typedData.primaryType).toBe("ReceiveWithAuthorization");
    prepared = r.body;
  });

  it("creates the vault from the payer's signature, takes the fee, and returns an API key once", async () => {
    const signature = await payer.signTypedData(hydrateAuthTypedData(prepared.typedData) as any);
    const r = await api("POST", "/v1/orgs", { prepareId: prepared.prepareId, signature }, platform);
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    expect(r.body.vault.toLowerCase()).toBe(prepared.vaultAddress.toLowerCase());
    expect(r.body.apiKey).toMatch(/^bco_/);
    vault = r.body.vault;
    apiKey = r.body.apiKey;

    expect(await balance(dep.feeRecipient)).toBe(5n * U);
    expect(await balance(payer.address)).toBe(95n * U);
    expect(await pc.readContract({ address: dep.factory, abi: [{ type: "function", name: "isOrg", inputs: [{ type: "address" }], outputs: [{ type: "bool" }], stateMutability: "view" }], functionName: "isOrg", args: [vault] })).toBe(true);
  });

  it("a preparation cannot be used twice", async () => {
    const signature = await payer.signTypedData(hydrateAuthTypedData(prepared.typedData) as any);
    const r = await api("POST", "/v1/orgs", { prepareId: prepared.prepareId, signature }, platform);
    expect(r.status).toBe(409);
  });

  it("rejects a signature from someone other than the payer, without taking any fee", async () => {
    const p = await api(
      "POST",
      "/v1/orgs/prepare",
      { payer: payer.address, init: { approvers: [approvers[0]!.address], budgets: [{ id: "GENERAL", limit: "1000", periodMonths: 1 }] } },
      platform,
    );
    const bad = await outsider.signTypedData(hydrateAuthTypedData(p.body.typedData) as any);
    const feeBefore = await balance(dep.feeRecipient);
    const r = await api("POST", "/v1/orgs", { prepareId: p.body.prepareId, signature: bad }, platform);
    expect(r.status).toBe(422);
    expect(r.body.error.message).toMatch(/AuthInvalidSignature/);
    expect(await balance(dep.feeRecipient)).toBe(feeBefore);
  });

  it("requires GENERAL budget", async () => {
    const r = await api(
      "POST",
      "/v1/orgs/prepare",
      { payer: payer.address, init: { approvers: [approvers[0]!.address], budgets: [{ id: "OTHER", limit: "1000", periodMonths: 1 }] } },
      platform,
    );
    expect(r.status).toBe(400);
  });

  it("reads the vault configuration", async () => {
    const r = await api("GET", `/v1/orgs/${vault}`);
    expect(r.status).toBe(200);
    expect(r.body.approvers).toHaveLength(5);
    expect(r.body.tiers.map((t: any) => t.approvals)).toEqual([1, 3, 5]);
    expect(r.body.governanceApprovals).toBe(5);
  });
});

describe("auth", () => {
  it("rejects missing and wrong keys", async () => {
    expect((await api("GET", `/v1/orgs/${vault}/treasury`, undefined, {})).status).toBe(401);
    expect((await api("GET", `/v1/orgs/${vault}/treasury`, undefined, H("bco_wrong"))).status).toBe(401);
  });
  it("unknown business is 404", async () => {
    expect((await api("GET", `/v1/orgs/0x${"12".repeat(20)}`)).status).toBe(404);
  });
});

describe("funding", () => {
  it("deposits with one gasless EIP-3009 signature", async () => {
    const prep = await api("POST", `/v1/orgs/${vault}/deposits/prepare`, { from: treasurer.address, value: String(2_000_000n * U) });
    expect(prep.status).toBe(200);
    const signature = await treasurer.signTypedData(hydrateAuthTypedData(prep.body.typedData) as any);
    const r = await api("POST", `/v1/orgs/${vault}/deposits`, {
      from: treasurer.address,
      value: String(2_000_000n * U),
      validAfter: prep.body.validAfter,
      validBefore: prep.body.validBefore,
      nonce: prep.body.nonce,
      signature,
    });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    const t = await api("GET", `/v1/orgs/${vault}/treasury`);
    expect(t.body.totalAssets).toBe(String(2_000_000n * U));
    expect(t.body.availableToSpend).toBe(String(2_000_000n * U));
  });

  it("a deposit signature signed by the wrong person fails and moves nothing", async () => {
    const prep = await api("POST", `/v1/orgs/${vault}/deposits/prepare`, { from: treasurer.address, value: String(10n * U) });
    const signature = await outsider.signTypedData(hydrateAuthTypedData(prep.body.typedData) as any);
    const r = await api("POST", `/v1/orgs/${vault}/deposits`, {
      from: treasurer.address, value: String(10n * U), validAfter: prep.body.validAfter, validBefore: prep.body.validBefore, nonce: prep.body.nonce, signature,
    });
    expect(r.status).toBe(422);
  });
});

describe("payments", () => {
  it("one approval pays a small invoice end to end", async () => {
    const done = await runThrough(`/v1/orgs/${vault}/payments`, { payee: vendor, amount: String(500n * U), ref: "INV-001", label: "Acme" }, 1);
    expect(done.txHash).toMatch(/^0x/);
    expect(await balance(vendor)).toBe(500n * U);
  });

  it("the stored typed data is exactly what the contract verifies (digest + domain)", async () => {
    const created = await api("POST", `/v1/orgs/${vault}/payments`, { payee: vendor, amount: String(10n * U) });
    expect(created.body.typedData.domain.name).toBe("BetterCallOps");
    expect(created.body.typedData.domain.verifyingContract.toLowerCase()).toBe(vault.toLowerCase());
    expect(created.body.typedData.domain.chainId).toBe(31337);
    await approve(created.body.id, 0);
    await waitStatus(created.body.id, "CONFIRMED");
  });

  it("three approvals at 1,000 USDT; boundary values pick the right tier", async () => {
    await runThrough(`/v1/orgs/${vault}/payments`, { payee: vendor, amount: String(1_000n * U) }, 3);
    const edge = await api("POST", `/v1/orgs/${vault}/payments`, { payee: vendor, amount: "999990000" });
    expect(edge.body.required).toBe(1);
    const mid = await api("POST", `/v1/orgs/${vault}/payments`, { payee: vendor, amount: String(5_000n * U) });
    expect(mid.body.required).toBe(3);
    const top = await api("POST", `/v1/orgs/${vault}/payments`, { payee: vendor, amount: "5000010000" });
    expect(top.body.required).toBe(5);
  });

  it("does not submit until the threshold is met, and rejects bad approvals", async () => {
    const created = await api("POST", `/v1/orgs/${vault}/payments`, { payee: vendor, amount: String(2_000n * U) });
    const rid = created.body.id;

    const first = await approve(rid, 0);
    expect(first.body.status).toBe("PENDING_APPROVAL");
    expect(first.body.approvals).toHaveLength(1);

    // same approver twice
    expect((await approve(rid, 0)).status).toBe(409);
    // not an approver
    expect((await approve(rid, outsider)).status).toBe(403);
    // signature does not match claimed signer
    const sig = await sign(created.body, approvers[3]!);
    const wrong = await api("POST", `/v1/requests/${rid}/approvals`, { signer: approvers[1]!.address, signature: sig });
    expect(wrong.status).toBe(400);
    expect(wrong.body.error.code).toBe("INVALID_SIGNATURE");

    // signature over different data (another request's) is refused
    const other = await api("POST", `/v1/orgs/${vault}/payments`, { payee: vendor, amount: String(2_000n * U) });
    const sigOther = await sign(other.body, approvers[1]!);
    expect((await api("POST", `/v1/requests/${rid}/approvals`, { signer: approvers[1]!.address, signature: sigOther })).status).toBe(400);

    await approve(rid, 1);
    const last = await approve(rid, 2);
    expect(last.body.status).toBe("APPROVED");
    await waitStatus(rid, "CONFIRMED");
    await api("POST", `/v1/requests/${other.body.id}/cancel`);
  });

  it("any approver can reject; non-approvers cannot", async () => {
    const created = await api("POST", `/v1/orgs/${vault}/payments`, { payee: vendor, amount: String(100n * U) });
    expect((await api("POST", `/v1/requests/${created.body.id}/reject`, { by: outsider.address })).status).toBe(403);
    const rej = await api("POST", `/v1/requests/${created.body.id}/reject`, { by: approvers[2]!.address, note: "wrong vendor" });
    expect(rej.body.status).toBe("REJECTED");
    expect((await approve(created.body.id, 0)).status).toBe(409);
  });

  it("reimbursements are reviewed before approvers are asked", async () => {
    const created = await api("POST", `/v1/orgs/${vault}/reimbursements`, { payee: employee, amount: String(80n * U), ref: "receipt-9" });
    expect(created.body.status).toBe("PENDING_REVIEW");
    expect((await approve(created.body.id, 0)).status).toBe(409);
    const reviewed = await api("POST", `/v1/requests/${created.body.id}/review`, { decision: "verified", note: "receipt ok" });
    expect(reviewed.body.status).toBe("PENDING_APPROVAL");
    await approve(created.body.id, 0);
    await waitStatus(created.body.id, "CONFIRMED");
    expect(await balance(employee)).toBe(80n * U);
  });

  it("a declined reimbursement ends there", async () => {
    const created = await api("POST", `/v1/orgs/${vault}/reimbursements`, { payee: employee, amount: String(5n * U) });
    const r = await api("POST", `/v1/requests/${created.body.id}/review`, { decision: "declined" });
    expect(r.body.status).toBe("REJECTED");
  });

  it("pre-flight refuses payments that can never succeed", async () => {
    const stranger = await api("POST", `/v1/orgs/${vault}/payments`, { payee: outsider.address, amount: "1000" });
    expect(stranger.status).toBe(422);
    expect(stranger.body.error.message).toMatch(/not registered/);
    const over = await api("POST", `/v1/orgs/${vault}/payments`, { payee: vendor, amount: String(10_000_000n * U) });
    expect(over.status).toBe(422);
    const noBudget = await api("POST", `/v1/orgs/${vault}/payments`, { payee: vendor, amount: "1000", budgetId: "NOPE" });
    expect(noBudget.status).toBe(422);
  });

  it("a payment the vault would refuse is FAILED with the decoded error and nothing is sent", async () => {
    // spend most of the monthly budget, then create a request while there is still room, and
    // exhaust the budget before the request is submitted
    const a = await api("POST", `/v1/orgs/${vault}/payments`, { payee: vendor, amount: String(50_000n * U) });
    const b = await api("POST", `/v1/orgs/${vault}/payments`, { payee: vendor, amount: String(50_000n * U) });
    for (let i = 0; i < 5; i++) await approve(a.body.id, i);
    await waitStatus(a.body.id, "CONFIRMED");
    for (let i = 0; i < 5; i++) await approve(b.body.id, i);
    const failed = await api("GET", `/v1/requests/${b.body.id}`).then(async (x) => (x.body.status === "FAILED" ? x.body : waitFailed(b.body.id)));
    expect(failed.error).toMatch(/BudgetExceeded/);
    expect(failed.txHash).toBeUndefined();
  });
});

async function waitFailed(rid: string) {
  const start = Date.now();
  for (;;) {
    const r = await api("GET", `/v1/requests/${rid}`);
    if (r.body.status === "FAILED") return r.body;
    if (r.body.status === "CONFIRMED") throw new Error("unexpectedly confirmed");
    if (Date.now() - start > 30_000) throw new Error(`timeout; at ${r.body.status}`);
    await new Promise((res) => setTimeout(res, 100));
  }
}

describe("idempotency and limits", () => {
  it("replays the same response for the same Idempotency-Key", async () => {
    const h = H(apiKey, { "idempotency-key": "key-123" });
    const body = { payee: vendor, amount: String(7n * U) };
    const a = await api("POST", `/v1/orgs/${vault}/payments`, body, h);
    const b = await api("POST", `/v1/orgs/${vault}/payments`, body, h);
    expect(a.status).toBe(201);
    expect(b.body.id).toBe(a.body.id);
    expect(b.raw.headers["idempotent-replay"]).toBe("true");
    const c = await api("POST", `/v1/orgs/${vault}/payments`, body, H(apiKey, { "idempotency-key": "key-456" }));
    expect(c.body.id).not.toBe(a.body.id);
  });

  it("validates input", async () => {
    expect((await api("POST", `/v1/orgs/${vault}/payments`, { payee: "nope", amount: "1" })).status).toBe(400);
    expect((await api("POST", `/v1/orgs/${vault}/payments`, { payee: vendor, amount: "-5" })).status).toBe(400);
  });
});

describe("governance and stale approvals", () => {
  it("adding a payee needs the payee-tier approvals and then the payee can be paid", async () => {
    const newPayee = newAccount().address;
    await runThrough(`/v1/orgs/${vault}/payees`, { action: "add", address: newPayee }, 3);
    await runThrough(`/v1/orgs/${vault}/payments`, { payee: newPayee, amount: String(20n * U) }, 1);
    expect(await balance(newPayee)).toBe(20n * U);
  });

  it("changes a budget through governance (all 5 approvers)", async () => {
    await runThrough(`/v1/orgs/${vault}/budgets`, { id: "MARKETING", limit: String(3_000n * U), periodMonths: 3 }, 5);
    const b = await api("GET", `/v1/orgs/${vault}/budgets?budgetId=MARKETING`);
    expect(b.body.limit).toBe(String(3_000n * U));
  });

  it("drops stale approvals when the approver set changes mid-flight, then recovers", async () => {
    // payment needs 3. Two approvals collected, one from an approver who is then removed.
    const pay = await api("POST", `/v1/orgs/${vault}/payments`, { payee: vendor, amount: String(1_500n * U) });
    await approve(pay.body.id, 4); // will be removed
    await approve(pay.body.id, 0);

    // remove approver #4 via governance (needs all 5 to sign, clamp = 5)
    await runThrough(`/v1/orgs/${vault}/governance`, { action: "RemoveApprover", address: approvers[4]!.address }, 5);

    // third approval arrives: threshold of 3 reached by count, but one is stale
    const third = await approve(pay.body.id, 1);
    expect(third.body.status).toBe("APPROVED");
    const back = await waitStatus(pay.body.id, "PENDING_APPROVAL");
    expect(back.approvals.map((a: any) => a.signer)).not.toContain(approvers[4]!.address);
    expect(back.error).toMatch(/approver set changed/);

    // a fresh valid approval completes it
    await approve(pay.body.id, 2);
    await waitStatus(pay.body.id, "CONFIRMED");
  });
});

describe("schedules", () => {
  it("creates a schedule, then pays a due run with fresh approvals", async () => {
    const now = BigInt(Math.floor(Date.now() / 1000));
    const created = await runThrough(
      `/v1/orgs/${vault}/schedules`,
      { payee: vendor, amount: String(300n * U), start: String(now - 3600n), unit: "DAY", every: 1, label: "hosting" },
      1,
    );
    expect(created.meta.onchainId).toBe("0");

    const list = await api("GET", `/v1/orgs/${vault}/schedules`);
    expect(list.body.schedules).toHaveLength(1);
    expect(list.body.schedules[0].nextRun).toBe("0");

    const before = await balance(vendor);
    await runThrough(`/v1/orgs/${vault}/schedules/0/runs/0`, {}, 1);
    expect(await balance(vendor)).toBe(before + 300n * U);

    const list2 = await api("GET", `/v1/orgs/${vault}/schedules`);
    expect(list2.body.schedules[0].nextRun).toBe("1");

    // the same run cannot be paid again
    const again = await api("POST", `/v1/orgs/${vault}/schedules/0/runs/0`, {});
    await approve(again.body.id, 0);
    const failed = await waitFailed(again.body.id);
    expect(failed.error).toMatch(/RunAlreadyPaid/);
  });

  it("cancelling needs one approval and stops the schedule", async () => {
    await runThrough(`/v1/orgs/${vault}/schedules/0`.replace(/^/, ""), undefined, 1, 0, "DELETE");
    const list = await api("GET", `/v1/orgs/${vault}/schedules`);
    expect(list.body.schedules[0].active).toBe(false);
    // no new runs can be requested for a cancelled schedule
    const run = await api("POST", `/v1/orgs/${vault}/schedules/0/runs/1`, {});
    expect(run.status).toBe(422);
    expect(run.body.error.message).toMatch(/not active/);
  });
});

describe("allowlist enforced on the live relayer", () => {
  it("refuses to send to an arbitrary contract", async () => {
    await expect(
      ctx.submitter.send({ to: outsider.address, abi: orgVaultAbi as any, functionName: "sweep", args: [] }),
    ).rejects.toThrow(NotAllowedError);
  });
  it("refuses functions outside the list (a token transfer, via the vault ABI-less path)", async () => {
    await expect(
      ctx.allowlist.assertAllowed({ to: vault, data: "0xa9059cbb" + "00".repeat(64) as Hex }),
    ).rejects.toThrow(/vault selector/);
  });
});

describe("expiry", () => {
  it("marks unsubmitted requests past validBefore as EXPIRED", async () => {
    const created = await api("POST", `/v1/orgs/${vault}/payments`, { payee: vendor, amount: String(3n * U) });
    const n = await ctx.requests.expireDue(Math.floor(Date.now() / 1000) + 10 * 86400);
    expect(n).toBeGreaterThan(0);
    const r = await api("GET", `/v1/requests/${created.body.id}`);
    expect(r.body.status).toBe("EXPIRED");
    expect((await approve(created.body.id, 0)).status).toBe(409);
  });
});

describe("vesting and sweep (time travel; keep last)", () => {
  it("locks funds, then anyone can trigger a release that pays only the beneficiary", async () => {
    const now = BigInt(Math.floor(Date.now() / 1000));
    const before = await balance(employee);
    const done = await runThrough(
      `/v1/orgs/${vault}/vestings`,
      { beneficiary: employee, total: String(12_000n * U), start: String(now), cliffMonths: 0, durationMonths: 12, stepMonths: 0, revocable: true, budgetId: "COMPENSATION" },
      4, // five approvers originally; one was removed in the governance test, so the top tier clamps to 4
    );
    expect(done.meta.onchainId).toBe("0");

    const t = await api("GET", `/v1/orgs/${vault}/treasury`);
    expect(t.body.reservedVesting).toBe(String(12_000n * U));

    // nothing vested yet
    const early = await api("POST", `/v1/orgs/${vault}/vestings/0/release`, {});
    expect(early.status).toBe(422);
    expect(early.body.error.message).toMatch(/NothingToRelease/);

    // six months pass
    await testClient.increaseTime({ seconds: 182 * 86400 });
    await testClient.mine({ blocks: 1 });
    const v = await api("GET", `/v1/orgs/${vault}/vestings/0`);
    expect(BigInt(v.body.releasable)).toBeGreaterThan(5_900n * U);

    const rel = await api("POST", `/v1/orgs/${vault}/vestings/0/release`, {});
    expect(rel.status, JSON.stringify(rel.body)).toBe(201);
    const got = (await balance(employee)) - before;
    expect(got).toBeGreaterThan(5_900n * U);
    expect(got).toBeLessThan(6_100n * U);
  });

  it("sweeps idle USDT to the pool when asked", async () => {
    const r = await api("POST", `/v1/orgs/${vault}/sweep`, {});
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    const t = await api("GET", `/v1/orgs/${vault}/treasury`);
    expect(BigInt(t.body.pool)).toBe(500_000n * U);
    const again = await api("POST", `/v1/orgs/${vault}/sweep`, {});
    expect(again.status).toBe(422);
    expect(again.body.error.message).toMatch(/NothingToSweep/);
  });
});
