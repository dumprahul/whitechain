import { spawn, type ChildProcess } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createPublicClient,
  createTestClient,
  createWalletClient,
  http,
  type Address,
  type Hex,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { mockUsdtAbi, orgFactoryAbi } from "../../src/chain/abis.js";
import { VAULT_TYPES, type PrimaryType } from "../../src/chain/typedData.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");

function artifact(name: string) {
  const j = JSON.parse(readFileSync(join(root, "out", `${name}.sol`, `${name}.json`), "utf8"));
  return { abi: j.abi, bytecode: j.bytecode.object as Hex };
}

export interface Chain {
  rpc: string;
  proc: ChildProcess;
  stop: () => void;
}

let nextPort = 8600 + Math.floor(Math.random() * 300);

export async function startAnvil(): Promise<Chain> {
  const port = nextPort++;
  const rpc = `http://127.0.0.1:${port}`;
  const proc = spawn("anvil", ["--port", String(port), "--silent"], { stdio: "ignore" });
  const pc = createPublicClient({ transport: http(rpc) });
  for (let i = 0; i < 100; i++) {
    try {
      await pc.getChainId();
      return { rpc, proc, stop: () => proc.kill() };
    } catch {
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  proc.kill();
  throw new Error("anvil did not start");
}

export function newAccount() {
  return privateKeyToAccount(generatePrivateKey());
}

export interface Deployment {
  usdt: Address;
  pool: Address;
  factory: Address;
  implementation: Address;
  relayerKey: Hex;
  owner: ReturnType<typeof newAccount>;
  feeRecipient: Address;
}

/** Deploys MockUSDT, MockAavePool, OrgFactory and the OrgVault implementation, wired together. */
export async function deployAll(rpc: string): Promise<Deployment> {
  const test = createTestClient({ mode: "anvil", transport: http(rpc) });
  const pc = createPublicClient({ transport: http(rpc) });
  const owner = newAccount();
  const relayerKey = generatePrivateKey();
  const relayer = privateKeyToAccount(relayerKey);
  const feeRecipient = newAccount().address;
  for (const a of [owner.address, relayer.address]) await test.setBalance({ address: a, value: 10n ** 21n });
  const wallet = createWalletClient({ account: owner, transport: http(rpc), chain: undefined });

  const deploy = async (name: string, args: unknown[]): Promise<Address> => {
    const { abi, bytecode } = artifact(name);
    const hash = await wallet.deployContract({ abi, bytecode, args, chain: null } as any);
    const r = await pc.waitForTransactionReceipt({ hash });
    return r.contractAddress!;
  };

  const usdt = await deploy("MockUSDT", []);
  const pool = await deploy("MockAavePool", [usdt, 6, owner.address]);
  const aToken = (await pc.readContract({ address: pool, abi: artifact("MockAavePool").abi, functionName: "aToken" })) as Address;
  const factory = await deploy("OrgFactory", [usdt, 5_000_000n, feeRecipient, owner.address]);
  const implementation = await deploy("OrgVault", [factory, usdt, pool, aToken, 1_000_000n]);
  const h = await wallet.writeContract({ address: factory, abi: orgFactoryAbi, functionName: "setImplementation", args: [implementation], chain: null });
  await pc.waitForTransactionReceipt({ hash: h });

  return { usdt, pool, factory, implementation, relayerKey, owner, feeRecipient };
}

export async function mintUsdt(rpc: string, usdt: Address, to: Address, amount: bigint, signer = newAccount()) {
  const test = createTestClient({ mode: "anvil", transport: http(rpc) });
  const pc = createPublicClient({ transport: http(rpc) });
  await test.setBalance({ address: signer.address, value: 10n ** 20n });
  const w = createWalletClient({ account: signer, transport: http(rpc) });
  const hash = await w.writeContract({ address: usdt, abi: mockUsdtAbi, functionName: "mint", args: [to, amount], chain: null } as any);
  await pc.waitForTransactionReceipt({ hash });
}

/** API responses carry bigints as strings; turn a vault request's typed data back into signable form. */
export function hydrateVaultTypedData(td: any) {
  const fields = VAULT_TYPES[td.primaryType as PrimaryType];
  const message: Record<string, unknown> = { ...td.message };
  for (const f of fields) if (f.type.startsWith("uint")) message[f.name] = BigInt(message[f.name] as string);
  return { domain: td.domain, types: td.types, primaryType: td.primaryType, message };
}

export function hydrateAuthTypedData(td: any) {
  const message = { ...td.message };
  for (const k of ["value", "validAfter", "validBefore"]) message[k] = BigInt(message[k]);
  return { domain: td.domain, types: td.types, primaryType: td.primaryType, message };
}
