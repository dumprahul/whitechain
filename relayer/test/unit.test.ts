import { describe, expect, it } from "vitest";
import { decodeAbiParameters, encodeErrorResult, keccak256, toBytes, type Address, type Hex } from "viem";
import { mockUsdtAbi, orgVaultAbi } from "../src/chain/abis.js";
import { Allowlist, FACTORY_SELECTORS, NotAllowedError, VAULT_SELECTORS } from "../src/chain/allowlist.js";
import { buildVaultCall, sortApprovals } from "../src/chain/calls.js";
import { decodeRevertReason } from "../src/chain/errors.js";
import { encodeGovData, GOV_ACTIONS, govActionIndex, buildTypedData, digestOf } from "../src/chain/typedData.js";
import { loadConfig } from "../src/config.js";
import { buildMessage } from "../src/requests/builders.js";
import { assertTransition, canTransition, InvalidTransitionError, isTerminal } from "../src/requests/stateMachine.js";
import { toBytes32Id } from "../src/orgs/service.js";
import type { RequestStatus } from "../src/store/types.js";

const A = "0x00000000000000000000000000000000000000a1" as Address;
const B = "0x00000000000000000000000000000000000000b2" as Address;
const C = "0x00000000000000000000000000000000000000c3" as Address;

describe("state machine", () => {
  it("allows the documented happy path", () => {
    const path: RequestStatus[] = ["DRAFT", "PENDING_REVIEW", "PENDING_APPROVAL", "APPROVED", "SUBMITTED", "CONFIRMED"];
    for (let i = 0; i < path.length - 1; i++) expect(canTransition(path[i]!, path[i + 1]!)).toBe(true);
  });
  it("lets approved requests fall back when the approver set changes", () => {
    expect(canTransition("APPROVED", "PENDING_APPROVAL")).toBe(true);
  });
  it("terminal states are final", () => {
    for (const s of ["REJECTED", "EXPIRED", "CANCELLED", "FAILED"] as const) {
      expect(isTerminal(s)).toBe(true);
      for (const t of ["PENDING_APPROVAL", "APPROVED", "SUBMITTED", "CONFIRMED"] as const) expect(canTransition(s, t)).toBe(false);
    }
  });
  it("cannot skip approval or leave SUBMITTED for pending", () => {
    expect(canTransition("PENDING_APPROVAL", "SUBMITTED")).toBe(false);
    expect(canTransition("PENDING_APPROVAL", "CONFIRMED")).toBe(false);
    expect(canTransition("SUBMITTED", "PENDING_APPROVAL")).toBe(false);
    expect(() => assertTransition("REJECTED", "APPROVED")).toThrow(InvalidTransitionError);
  });
  it("a reorg can move a confirmed request back to submitted", () => {
    expect(canTransition("CONFIRMED", "SUBMITTED")).toBe(true);
  });
});

describe("approvals ordering", () => {
  it("sorts strictly ascending by signer address", () => {
    const sorted = sortApprovals([
      { signer: C, signature: "0x03" },
      { signer: A, signature: "0x01" },
      { signer: B, signature: "0x02" },
    ]);
    expect(sorted.map((x) => x.signer)).toEqual([A, B, C]);
  });
});

describe("call builder", () => {
  const approvals = [{ signer: A, signature: "0x01" as Hex }];
  it("maps every request type to its vault function", () => {
    const base = { nonce: 1n, validBefore: 2n };
    expect(buildVaultCall("PAYMENT", { kind: 0, payee: A, amount: 1n, budgetId: "0x", ref: "0x", ...base }, approvals).functionName).toBe("executePayment");
    expect(buildVaultCall("REIMBURSEMENT", { kind: 1, payee: A, amount: 1n, budgetId: "0x", ref: "0x", ...base }, approvals).functionName).toBe("executePayment");
    expect(buildVaultCall("SCHEDULE_CREATE", { payee: A, amount: 1n, start: 1n, end: 0n, unit: 0, every: 1, budgetId: "0x", ref: "0x", ...base }, approvals).functionName).toBe("createSchedule");
    expect(buildVaultCall("SCHEDULED_RUN", { scheduleId: 1n, run: 0n, validBefore: 2n }, approvals).functionName).toBe("executeScheduledRun");
    expect(buildVaultCall("SCHEDULE_CANCEL", { scheduleId: 1n, ...base }, approvals).functionName).toBe("cancelSchedule");
    expect(buildVaultCall("VESTING_CREATE", { beneficiary: A, total: 1n, start: 1n, cliffMonths: 0, durationMonths: 1, stepMonths: 0, revocable: false, budgetId: "0x", ref: "0x", ...base }, approvals).functionName).toBe("createVesting");
    expect(buildVaultCall("RECALL", { amount: 1n, ...base }, approvals).functionName).toBe("recall");
    expect(buildVaultCall("INVALIDATE_NONCE", { target: 1n, ...base }, approvals).functionName).toBe("invalidateNonce");
    expect(buildVaultCall("GOVERNANCE", { action: 0, data: "0x", ...base }, approvals).functionName).toBe("executeGovernance");
  });
  it("sorts approvals inside the call", () => {
    const call = buildVaultCall("RECALL", { amount: 1n, nonce: 1n, validBefore: 2n }, [
      { signer: C, signature: "0x03" },
      { signer: A, signature: "0x01" },
    ]);
    const list = call.args[3] as { signer: Address }[];
    expect(list.map((x) => x.signer)).toEqual([A, C]);
  });
  it("only forwards fields the contract struct has (no client-injected extras)", () => {
    const call = buildVaultCall("PAYMENT", { kind: 0, payee: A, amount: 1n, budgetId: "0x", ref: "0x", nonce: 1n, validBefore: 2n, evil: "x" }, approvals);
    expect(Object.keys(call.args[0] as object).sort()).toEqual(["amount", "budgetId", "kind", "nonce", "payee", "ref", "validBefore"]);
  });
});

describe("governance encoding", () => {
  it("round-trips the encodings the vault decodes", () => {
    expect((decodeAbiParameters([{ type: "address" }], encodeGovData({ action: "AddPayee", address: A }))[0] as string).toLowerCase()).toBe(A);
    const budget = decodeAbiParameters([{ type: "bytes32" }, { type: "uint128" }, { type: "uint16" }], encodeGovData({ action: "SetBudget", budgetId: keccak256(toBytes("X")), limit: 5n, periodMonths: 3 }));
    expect(budget[1]).toBe(5n);
    expect(budget[2]).toBe(3);
    const gp = decodeAbiParameters([{ type: "uint8" }, { type: "uint8" }], encodeGovData({ action: "SetGovernanceParams", payeeApprovals: 2, governanceApprovals: 3 }));
    expect(gp).toEqual([2, 3]);
  });
  it("action indexes match GovAction in OrgTypes.sol", () => {
    expect(govActionIndex("AddApprover")).toBe(0);
    expect(govActionIndex("SetBudget")).toBe(3);
    expect(govActionIndex("RevokeVesting")).toBe(5);
    expect(govActionIndex("AddPayee")).toBe(8);
    expect(govActionIndex("RemovePayee")).toBe(9);
    expect(GOV_ACTIONS.length).toBe(10);
  });
});

describe("typed data", () => {
  it("is deterministic and bound to the vault address and chain", () => {
    const m = buildMessage({ type: "RECALL", amount: 5n }, 100n);
    const a = buildTypedData(1874, A, "Recall", { ...m.message, nonce: 1n });
    const b = buildTypedData(1874, B, "Recall", { ...m.message, nonce: 1n });
    const c = buildTypedData(1, A, "Recall", { ...m.message, nonce: 1n });
    expect(digestOf(a)).toBe(digestOf(a));
    expect(digestOf(a)).not.toBe(digestOf(b));
    expect(digestOf(a)).not.toBe(digestOf(c));
  });
  it("assigns a fresh random nonce per request", () => {
    const n1 = buildMessage({ type: "RECALL", amount: 5n }, 100n).nonce;
    const n2 = buildMessage({ type: "RECALL", amount: 5n }, 100n).nonce;
    expect(n1).not.toBe(n2);
  });
  it("scheduled runs carry no nonce", () => {
    expect(buildMessage({ type: "SCHEDULED_RUN", scheduleId: 1n, run: 0n }, 100n).nonce).toBeUndefined();
  });
});

describe("allowlist", () => {
  const FACTORY = A;
  const VAULT = B;
  const mk = (registered: Address[]) =>
    new Allowlist({
      factory: FACTORY,
      chainId: 1874,
      publicClient: { readContract: async ({ args }: any) => registered.includes(args[0]) } as any,
    });
  const sel = [...VAULT_SELECTORS][0]!;
  const factorySel = [...FACTORY_SELECTORS][0]!;

  it("allows registered vaults with listed functions", async () => {
    await expect(mk([VAULT]).assertAllowed({ to: VAULT, data: sel, value: 0n, chainId: 1874 })).resolves.toBeUndefined();
  });
  it("allows createOrg on the factory only", async () => {
    await expect(mk([]).assertAllowed({ to: FACTORY, data: factorySel })).resolves.toBeUndefined();
    await expect(mk([]).assertAllowed({ to: FACTORY, data: sel })).rejects.toThrow(NotAllowedError);
  });
  it("rejects unregistered targets", async () => {
    await expect(mk([]).assertAllowed({ to: C, data: sel })).rejects.toThrow(/not a registered vault/);
  });
  it("rejects functions outside the fixed list", async () => {
    await expect(mk([VAULT]).assertAllowed({ to: VAULT, data: "0xa9059cbb" })).rejects.toThrow(/vault selector/); // ERC20 transfer
  });
  it("rejects any value", async () => {
    await expect(mk([VAULT]).assertAllowed({ to: VAULT, data: sel, value: 1n })).rejects.toThrow(/value/);
  });
  it("rejects the wrong chain", async () => {
    await expect(mk([VAULT]).assertAllowed({ to: VAULT, data: sel, chainId: 1 })).rejects.toThrow(/chain/);
  });
  it("caches registry hits", async () => {
    let reads = 0;
    const al = new Allowlist({ factory: FACTORY, chainId: 1874, publicClient: { readContract: async () => (reads++, true) } as any });
    await al.assertAllowed({ to: VAULT, data: sel });
    await al.assertAllowed({ to: VAULT, data: sel });
    expect(reads).toBe(1);
  });
  it("the allowed vault functions are exactly the documented list", () => {
    expect(VAULT_SELECTORS.size).toBe(11);
    expect(FACTORY_SELECTORS.size).toBe(1);
  });
});

describe("revert decoding", () => {
  it("decodes custom errors with arguments", () => {
    const data = encodeErrorResult({ abi: orgVaultAbi, errorName: "InsufficientApprovals", args: [2n, 3n] });
    expect(decodeRevertReason({ data })).toBe("InsufficientApprovals(2, 3)");
  });
  it("finds revert data nested in a cause chain", () => {
    const data = encodeErrorResult({ abi: orgVaultAbi, errorName: "Expired" });
    expect(decodeRevertReason({ cause: { cause: { data } } })).toBe("Expired()");
  });
  it("decodes token errors too", () => {
    const data = encodeErrorResult({ abi: mockUsdtAbi, errorName: "AuthInvalidSignature" });
    expect(decodeRevertReason({ data })).toBe("AuthInvalidSignature()");
  });
  it("falls back to the message", () => {
    expect(decodeRevertReason(new Error("boom"))).toBe("boom");
  });
});

describe("helpers", () => {
  it("toBytes32Id hashes names and passes 32-byte hex through", () => {
    expect(toBytes32Id("GENERAL")).toBe(keccak256(toBytes("GENERAL")));
    const raw = ("0x" + "11".repeat(32)) as Hex;
    expect(toBytes32Id(raw)).toBe(raw);
  });
  it("config rejects missing values with a readable error", () => {
    expect(() => loadConfig({})).toThrow(/Invalid configuration/);
  });
  it("config applies defaults", () => {
    const c = loadConfig({
      RPC_URL: "https://x.example",
      USDT_ADDRESS: A,
      FACTORY_ADDRESS: B,
      RELAYER_PRIVATE_KEY: "0x" + "11".repeat(32),
    });
    expect(c.CHAIN_ID).toBe(1874);
    expect(c.CONFIRMATIONS).toBe(3);
    expect(c.REQUEST_TTL_SECONDS).toBe(86400);
  });
});

import { cleanPrivyKey } from "../src/config.js";
describe("cleanPrivyKey", () => {
  it("removes quotes, prefix and whitespace; rejects PEM", () => {
    expect(cleanPrivyKey('  "AbC+/12=" \n')).toBe("AbC+/12=");
    expect(cleanPrivyKey("wallet-auth:AbC12")).toBe("AbC12");
    expect(cleanPrivyKey("   ")).toBeUndefined();
    expect(() => cleanPrivyKey("-----BEGIN PRIVATE KEY-----\nAAA\n-----END PRIVATE KEY-----")).toThrow(/plain base64/);
  });
});
