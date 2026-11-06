import { afterAll, beforeEach, describe, expect, it } from "vitest";
import { PgDb } from "../src/db/adapters.js";
import { MIGRATIONS, migrate } from "../src/db/migrations.js";
import { PgliteDb } from "../src/db/pglite.js";
import type { Db } from "../src/db/types.js";
import { MemoryStore } from "../src/store/memory.js";
import { PostgresStore } from "../src/store/postgres.js";
import type { OrgRecord, RequestRecord, Store } from "../src/store/types.js";

const ORG = "0x" + "ab".repeat(20);
const HASH = ("0x" + "11".repeat(32)) as `0x${string}`;

const org = (id = ORG): OrgRecord => ({ id, vault: id as any, payer: ("0x" + "cd".repeat(20)) as any, apiKeyHash: "hash", txHash: HASH, createdAt: 1000 });

function request(over: Partial<RequestRecord> = {}): RequestRecord {
  return {
    id: crypto.randomUUID(),
    orgId: ORG,
    type: "PAYMENT",
    typedData: {
      domain: { name: "BetterCallOps", version: "1", chainId: 1874, verifyingContract: ORG as any },
      types: { Payment: [{ name: "amount", type: "uint256" }] },
      primaryType: "Payment",
      message: { amount: 2n ** 200n + 7n, nonce: 12345678901234567890123456789n, label: "x" },
    },
    digest: HASH,
    amount: 2n ** 200n + 7n,
    nonce: 12345678901234567890123456789n,
    validBefore: 1_900_000_000,
    status: "PENDING_APPROVAL",
    required: 3,
    approvals: [{ signer: ("0x" + "01".repeat(20)) as any, signature: "0xdead", channel: "api", createdAt: 5 }],
    attempts: 0,
    meta: { label: "Acme", nested: { big: 99n } },
    createdAt: 2000,
    updatedAt: 2000,
    ...over,
  };
}

interface Backend {
  name: string;
  make: () => Promise<{ store: Store; close: () => Promise<void> }>;
}

const backends: Backend[] = [
  { name: "MemoryStore", make: async () => ({ store: new MemoryStore(), close: async () => {} }) },
  {
    name: "PostgresStore (PGlite)",
    make: async () => {
      const db = new PgliteDb();
      await migrate(db);
      return { store: new PostgresStore(db), close: () => db.close() };
    },
  },
];
if (process.env.TEST_DATABASE_URL) {
  backends.push({
    name: "PostgresStore (real Postgres)",
    make: async () => {
      const db = new PgDb(process.env.TEST_DATABASE_URL!);
      await db.query("DROP SCHEMA public CASCADE; CREATE SCHEMA public;");
      await migrate(db);
      return { store: new PostgresStore(db), close: () => db.close() };
    },
  });
}

describe.each(backends)("Store contract: $name", (backend) => {
  let store: Store;
  let close: () => Promise<void>;

  beforeEach(async () => {
    await close?.();
    ({ store, close } = await backend.make());
    await store.putOrg(org());
  });
  afterAll(async () => {
    await close?.();
  });

  it("stores and finds organizations (ids are case-insensitive on read)", async () => {
    expect((await store.getOrg(ORG))?.apiKeyHash).toBe("hash");
    expect((await store.getOrg(ORG.toUpperCase().replace("0X", "0x")))?.id).toBe(ORG);
    expect(await store.getOrg("0x" + "00".repeat(20))).toBeUndefined();
    await store.putOrg(org("0x" + "ee".repeat(20)));
    expect((await store.listOrgs()).map((o) => o.id)).toEqual([ORG, "0x" + "ee".repeat(20)]);
  });

  it("round-trips a request exactly, including huge integers inside JSON", async () => {
    const r = request();
    await store.putRequest(r);
    expect(await store.getRequest(r.id)).toEqual(r);
  });

  it("round-trips a request with every optional field set", async () => {
    const r = request({ txHash: HASH, error: "boom", reviewNote: "ok", rejectedBy: ("0x" + "02".repeat(20)) as any, status: "FAILED", attempts: 4 });
    await store.putRequest(r);
    expect(await store.getRequest(r.id)).toEqual(r);
  });

  it("updates in place", async () => {
    const r = request();
    await store.putRequest(r);
    await store.putRequest({ ...r, status: "CONFIRMED", txHash: HASH, updatedAt: 3000, approvals: [] });
    const got = await store.getRequest(r.id);
    expect(got?.status).toBe("CONFIRMED");
    expect(got?.approvals).toEqual([]);
    expect(got?.createdAt).toBe(2000);
    expect((await store.listRequests({})).length).toBe(1);
  });

  it("returns undefined for unknown requests and does not leak mutations", async () => {
    expect(await store.getRequest("nope")).toBeUndefined();
    const r = request();
    await store.putRequest(r);
    const a = await store.getRequest(r.id);
    a!.meta.label = "changed";
    expect((await store.getRequest(r.id))?.meta.label).toBe("Acme");
  });

  it("filters by org, status and type, ordered by creation time", async () => {
    await store.putOrg(org("0x" + "ee".repeat(20)));
    const a = request({ createdAt: 1, type: "PAYMENT", status: "PENDING_APPROVAL" });
    const b = request({ createdAt: 2, type: "REIMBURSEMENT", status: "PENDING_REVIEW" });
    const c = request({ createdAt: 3, type: "SCHEDULED_RUN", status: "CONFIRMED" });
    const d = request({ createdAt: 4, orgId: "0x" + "ee".repeat(20), status: "CONFIRMED" });
    for (const r of [c, a, d, b]) await store.putRequest(r);

    expect((await store.listRequests({})).map((r) => r.id)).toEqual([a.id, b.id, c.id, d.id]);
    expect((await store.listRequests({ orgId: ORG })).map((r) => r.id)).toEqual([a.id, b.id, c.id]);
    expect((await store.listRequests({ status: ["CONFIRMED"] })).map((r) => r.id)).toEqual([c.id, d.id]);
    expect((await store.listRequests({ status: ["PENDING_APPROVAL", "PENDING_REVIEW"] })).map((r) => r.id)).toEqual([a.id, b.id]);
    expect((await store.listRequests({ type: ["SCHEDULED_RUN"] })).map((r) => r.id)).toEqual([c.id]);
    expect((await store.listRequests({ orgId: ORG, status: ["CONFIRMED"], type: ["SCHEDULED_RUN"] })).map((r) => r.id)).toEqual([c.id]);
    expect(await store.listRequests({ status: [] })).toEqual([]);
  });

  it("prepared organizations", async () => {
    const p = {
      id: crypto.randomUUID(), payer: org().payer, initJson: '{"a":"bigint:5"}', salt: HASH, nonce: HASH,
      validAfter: 0, validBefore: 1_900_000_000, vaultAddress: org().vault, used: false, createdAt: 7,
    };
    await store.putPrepared(p);
    expect(await store.getPrepared(p.id)).toEqual(p);
    await store.putPrepared({ ...p, used: true });
    expect((await store.getPrepared(p.id))?.used).toBe(true);
    expect(await store.getPrepared("none")).toBeUndefined();
  });

  it("idempotency: the first write wins", async () => {
    await store.putIdempotent("k", { status: 201, body: '{"id":1}' });
    await store.putIdempotent("k", { status: 500, body: "other" });
    expect(await store.getIdempotent("k")).toEqual({ status: 201, body: '{"id":1}' });
    expect(await store.getIdempotent("missing")).toBeUndefined();
  });

  it("approver wallets: lookup is case-insensitive, listed oldest first, updated in place", async () => {
    const a = "0x" + "Ab".repeat(20);
    expect(await store.getApproverWallet(a)).toBeUndefined();
    await store.putApproverWallet({ address: a as any, privyWalletId: "w1", label: "Ana", createdAt: 2 });
    await store.putApproverWallet({ address: ("0x" + "cd".repeat(20)) as any, privyWalletId: "w2", label: "Bo", createdAt: 1 });
    expect((await store.getApproverWallet(a.toLowerCase()))?.privyWalletId).toBe("w1");
    expect((await store.listApproverWallets()).map((w) => w.label)).toEqual(["Bo", "Ana"]);
    await store.putApproverWallet({ address: a as any, privyWalletId: "w1", label: "Ana B", createdAt: 2 });
    expect((await store.getApproverWallet(a))?.label).toBe("Ana B");
    expect(await store.listApproverWallets()).toHaveLength(2);
  });

  it("key/value state", async () => {
    expect(await store.getKV("a")).toBeUndefined();
    await store.putKV("a", { t: 1, big: 10n ** 30n });
    expect(await store.getKV("a")).toEqual({ t: 1, big: 10n ** 30n });
    await store.putKV("a", 5);
    expect(await store.getKV("a")).toBe(5);
  });

  it("audit log keeps order and filters by org", async () => {
    await store.putOrg(org("0x" + "ee".repeat(20)));
    await store.audit({ actor: "x", action: "one", orgId: ORG });
    await store.audit({ actor: "y", action: "two", orgId: "0x" + "ee".repeat(20), detail: { n: 1n } });
    await store.audit({ actor: "z", action: "three" });
    expect((await store.listAudit({})).map((e) => e.action)).toEqual(["one", "two", "three"]);
    const only = await store.listAudit({ orgId: "0x" + "ee".repeat(20) });
    expect(only.map((e) => e.action)).toEqual(["two"]);
    expect(only[0]?.detail).toEqual({ n: 1n });
  });
});

describe("migrations", () => {
  let db: Db;
  beforeEach(async () => {
    await db?.close();
    db = new PgliteDb();
  });

  it("apply once and are idempotent", async () => {
    expect(await migrate(db)).toEqual(MIGRATIONS.map((m) => m.id));
    expect(await migrate(db)).toEqual([]);
    const rows = await db.query(`SELECT id FROM schema_migrations`);
    expect(rows.length).toBe(MIGRATIONS.length);
  });

  it("a failing migration rolls back completely and is retried next time", async () => {
    const bad = [{ id: 1, name: "bad", sql: `CREATE TABLE t1 (a int); SELECT * FROM does_not_exist;` }];
    await expect(migrate(db, bad)).rejects.toThrow();
    expect(await db.query(`SELECT to_regclass('t1') AS t`)).toEqual([{ t: null }]);
    expect(await db.query(`SELECT id FROM schema_migrations`)).toEqual([]);
  });

  it("enforces integrity: a request needs an existing organization", async () => {
    await migrate(db);
    const store = new PostgresStore(db);
    await expect(store.putRequest(request({ orgId: "0x" + "99".repeat(20) }))).rejects.toThrow(/foreign key|violates/i);
  });
});
