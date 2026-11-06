import { createPublicClient, createTestClient, http, parseAbi, type Address } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import type { FastifyInstance } from "fastify";
import { expect } from "vitest";
import { buildApp } from "../../src/api/server.js";
import { loadConfig, type Config } from "../../src/config.js";
import { createContext, type Context } from "../../src/context.js";
import type { Store } from "../../src/store/types.js";
import { FakePrivySigner } from "./fakePrivy.js";
import {
  deployAll,
  hydrateAuthTypedData,
  hydrateVaultTypedData,
  mintUsdt,
  newAccount,
  startAnvil,
  type Chain,
  type Deployment,
} from "./harness.js";

export const U = 1_000_000n;
const erc20 = parseAbi(["function balanceOf(address) view returns (uint256)"]);
const PLATFORM = "platform-secret-key-123";

export interface E2E {
  chain: Chain;
  dep: Deployment;
  ctx: Context;
  app: FastifyInstance;
  vault: Address;
  apiKey: string;
  approvers: ReturnType<typeof privateKeyToAccount>[];
  vendor: Address;
  employee: Address;
  /** Set when bootstrapped with `privy`: the stand-in wallet provider and the approvers' wallet addresses. */
  privy?: { signer: FakePrivySigner; addresses: Address[] };
  pc: ReturnType<typeof createPublicClient>;
  testClient: ReturnType<typeof createTestClient>;
  api: (method: "GET" | "POST" | "DELETE", url: string, body?: unknown) => Promise<{ status: number; body: any }>;
  balance: (who: Address) => Promise<bigint>;
  approve: (rid: string, approverIndex: number) => Promise<{ status: number; body: any }>;
  waitStatus: (rid: string, want: string) => Promise<any>;
  /** Create a request via the API, collect `n` approvals, wait for it to confirm. */
  runThrough: (path: string, body: unknown, n: number, method?: "POST" | "DELETE") => Promise<any>;
  chainTime: () => Promise<bigint>;
  stop: () => Promise<void>;
}

/** Full stack: anvil + deployed contracts + relayer context/API + one business with 5 approvers and funds. */
export async function bootstrap(opts: { store?: Store; config?: Record<string, string>; funding?: bigint; privy?: { approvers: number }; tiers?: { maxAmount: string; approvals: number }[] } = {}): Promise<E2E> {
  const chain = await startAnvil();
  const dep = await deployAll(chain.rpc);
  const pc = createPublicClient({ transport: http(chain.rpc) });
  const testClient = createTestClient({ mode: "anvil", transport: http(chain.rpc) });

  const approvers = Array.from({ length: 5 }, () => privateKeyToAccount(generatePrivateKey()));
  const payer = newAccount();
  const vendor = newAccount().address;
  const employee = newAccount().address;
  await mintUsdt(chain.rpc, dep.usdt, payer.address, 100n * U);

  const config: Config = loadConfig({
    CHAIN_ID: "31337",
    RPC_URL: chain.rpc,
    USDT_ADDRESS: dep.usdt,
    FACTORY_ADDRESS: dep.factory,
    RELAYER_PRIVATE_KEY: dep.relayerKey,
    CONFIRMATIONS: "0",
    POLLING_INTERVAL_MS: "50",
    PLATFORM_API_KEY: PLATFORM,
    RATE_LIMIT_PER_MINUTE: "10000",
    SCHEDULER_ENABLED: "false",
    ...opts.config,
  });
  const fakeSigner = opts.privy ? new FakePrivySigner() : undefined;
  const ctx = createContext(config, { store: opts.store, signer: fakeSigner });
  const app = buildApp(ctx);
  await app.ready();

  const call = async (method: string, url: string, body?: unknown, headers: Record<string, string> = {}) => {
    const res = await app.inject({ method: method as any, url, payload: body as any, headers });
    return { status: res.statusCode, body: res.json() as any };
  };

  // wallets for the ops team, created through the API like a real client would
  let privy: E2E["privy"];
  if (fakeSigner) {
    const addresses: Address[] = [];
    for (let i = 0; i < opts.privy!.approvers; i++) {
      const w = await call("POST", "/v1/approver-wallets", { label: `member ${i + 1}` }, { "x-api-key": PLATFORM });
      expect(w.status, JSON.stringify(w.body)).toBe(201);
      addresses.push(w.body.address);
    }
    privy = { signer: fakeSigner, addresses };
  }

  // create the business through the public API, like a real client
  const prep = await call(
    "POST",
    "/v1/orgs/prepare",
    {
      payer: payer.address,
      init: {
        approvers: privy ? privy.addresses : approvers.map((a) => a.address),
        ...(opts.tiers ? { tiers: opts.tiers, payeeApprovals: 2 } : {}),
        budgets: [
          { id: "GENERAL", limit: String(1_000_000n * U), periodMonths: 1 },
          { id: "COMPENSATION", limit: String(1_000_000n * U), periodMonths: 0 },
        ],
        sweep: { enabled: true, minLiquid: String(10_000n * U), maxInYield: String(500_000n * U) },
        payees: [vendor, employee],
      },
    },
    { "x-api-key": PLATFORM },
  );
  expect(prep.status, JSON.stringify(prep.body)).toBe(200);
  const sig = await payer.signTypedData(hydrateAuthTypedData(prep.body.typedData) as any);
  const created = await call("POST", "/v1/orgs", { prepareId: prep.body.prepareId, signature: sig }, { "x-api-key": PLATFORM });
  expect(created.status, JSON.stringify(created.body)).toBe(201);
  const vault = created.body.vault as Address;
  const apiKey = created.body.apiKey as string;
  await mintUsdt(chain.rpc, dep.usdt, vault, opts.funding ?? 2_000_000n * U);

  const api: E2E["api"] = (method, url, body) => call(method, url, body, { "x-api-key": apiKey });
  const approve: E2E["approve"] = async (rid, i) => {
    const r = await api("GET", `/v1/requests/${rid}`);
    const signature = await approvers[i]!.signTypedData(hydrateVaultTypedData(r.body.typedData) as any);
    return api("POST", `/v1/requests/${rid}/approvals`, { signer: approvers[i]!.address, signature });
  };
  const waitStatus: E2E["waitStatus"] = async (rid, want) => {
    const start = Date.now();
    for (;;) {
      const r = await api("GET", `/v1/requests/${rid}`);
      if (r.body.status === want) return r.body;
      if (["FAILED", "REJECTED", "EXPIRED", "CANCELLED"].includes(r.body.status)) throw new Error(`request ended as ${r.body.status}: ${r.body.error}`);
      if (Date.now() - start > 30_000) throw new Error(`timeout waiting for ${want}; at ${r.body.status}`);
      await new Promise((res) => setTimeout(res, 50));
    }
  };
  const runThrough: E2E["runThrough"] = async (path, body, n, method = "POST") => {
    const c = await api(method, path, body);
    expect(c.status, JSON.stringify(c.body)).toBe(201);
    expect(c.body.required).toBe(n);
    for (let i = 0; i < n; i++) await approve(c.body.id, i);
    return waitStatus(c.body.id, "CONFIRMED");
  };

  return {
    chain, dep, ctx, app, vault, apiKey, approvers, vendor, employee, privy, pc, testClient, api, approve, waitStatus, runThrough,
    balance: async (who) => (await pc.readContract({ address: dep.usdt, abi: erc20, functionName: "balanceOf", args: [who] })) as bigint,
    chainTime: async () => (await pc.getBlock()).timestamp,
    stop: async () => {
      ctx.scheduler.stop();
      ctx.submitter.stop();
      await app.close();
      chain.stop();
    },
  };
}
