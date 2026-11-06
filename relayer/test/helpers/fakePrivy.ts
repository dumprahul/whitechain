import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import type { Hex } from "viem";
import type { TypedPayload } from "../../src/chain/typedData.js";
import { toJsonTypedData, type ApproverSigner } from "../../src/privy/signer.js";

/**
 * Stands in for Privy: keeps keys locally. Like the real service it receives JSON (bigints as strings) and signs
 * only what it is given, so a lossy conversion on the relayer side would show up as an invalid signature.
 */
export class FakePrivySigner implements ApproverSigner {
  readonly wallets = new Map<string, ReturnType<typeof privateKeyToAccount>>();
  readonly signed: string[] = [];
  private n = 0;

  async createWallet(_label: string) {
    const account = privateKeyToAccount(generatePrivateKey());
    const walletId = `wallet_${++this.n}`;
    this.wallets.set(walletId, account);
    return { walletId, address: account.address };
  }

  async signTypedData(walletId: string, td: TypedPayload): Promise<Hex> {
    const account = this.wallets.get(walletId);
    if (!account) throw new Error(`unknown wallet ${walletId}`);
    const j = toJsonTypedData(td);
    const fields = j.types[j.primary_type]!;
    const message: Record<string, unknown> = { ...j.message };
    for (const f of fields) if (f.type.startsWith("uint")) message[f.name] = BigInt(message[f.name] as string);
    this.signed.push(j.primary_type);
    return account.signTypedData({ domain: j.domain, types: j.types, primaryType: j.primary_type, message } as any);
  }
}
