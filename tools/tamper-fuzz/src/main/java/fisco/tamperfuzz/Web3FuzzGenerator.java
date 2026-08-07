package fisco.tamperfuzz;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Random;
import org.web3j.crypto.Credentials;
import org.web3j.crypto.RawTransaction;
import org.web3j.crypto.Sign;
import org.web3j.crypto.SignedRawTransaction;
import org.web3j.crypto.TransactionDecoder;
import org.web3j.crypto.TransactionEncoder;
import org.web3j.utils.Numeric;

/**
 * Web3FuzzGenerator — the Web3-RPC analogue of FuzzGenerator (see that class's doc for the shared
 * contract). Invoked as `java -jar tamper-fuzz-all.jar web3fuzz <count> <seed> <strategy>`,
 * strategy in {struct, bytes, both}. Prints <count> TSV lines to stdout: `<idx>\t<kind>\t<detail>
 * \t<hex>`, kind in {struct, bytes}, hex a 0x-prefixed SIGNED-RLP legacy Ethereum transaction
 * ready for eth_sendRawTransaction. idx is 0..count-1. No other stdout.
 *
 * Signs with Web3J (pure-Java Bouncy Castle secp256k1, no JNI) against a FIXED test private key
 * (FIXED_PRIVATE_KEY_HEX below — same throwaway well-known dev key FuzzGenerator uses, reused here
 * only for its property of being a stable constant; never trust an address derived from it) and a
 * FIXED chain id (CHAIN_ID = 60600, the live FISCO Web3 RPC's configured chain id). Only a legacy
 * (pre-EIP-1559) transaction shape is produced — YAGNI: no typed-tx (EIP-1559/2930) support, this
 * generator's job is fuzzing the node's RLP decode + signature/field validation, not exercising
 * every wire format.
 *
 * DETERMINISM CONTRACT: identical to FuzzGenerator's — exactly one java.util.Random(seed) drives
 * every choice, in a FIXED per-idx call order (see generateStructMutant / generateBytesMutant), so
 * the same (count, seed, strategy) always replays the exact same sequence of Random draws and
 * therefore byte-identical output. Do NOT introduce System.nanoTime()/SecureRandom/HashMap
 * iteration order or any other non-seed-derived source of variation — `web3fuzz --selfcheck`
 * asserts this by generating the same corpus twice and diffing, mirroring `fuzz --selfcheck`.
 */
final class Web3FuzzGenerator {

    // Fixed test private key (secp256k1, 32 bytes) — same well-known throwaway dev key
    // FuzzGenerator.FIXED_PRIVATE_KEY_HEX uses (Hardhat's default account #0), duplicated here
    // rather than shared across classes to keep this generator self-contained. Never send funds to
    // or otherwise trust an address derived from this key.
    private static final String FIXED_PRIVATE_KEY_HEX =
            "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

    // Live-chain facts verified by the coordinator (see task brief) — not derived, hardcoded like
    // FuzzGenerator hardcodes its own base tx shape.
    static final long CHAIN_ID = 60600L;
    private static final BigInteger GAS_PRICE = BigInteger.valueOf(21000L);
    private static final BigInteger GAS_LIMIT = BigInteger.valueOf(3_000_000L);
    private static final String DEFAULT_TO = "0x1234567890123456789012345678901234567890";
    private static final String DEFAULT_DATA_HEX = "0xdeadbeef";
    private static final BigInteger MAX_UINT256 =
            new BigInteger(
                    "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF", 16);

    // TX-level fields first (indices 0..TX_FIELD_COUNT-1, each additionally draws a reSign
    // boolean), signature (v/r/s) last (no reSign axis — mutating v/r/s directly IS the point,
    // there is nothing to "re-sign" over). Order is part of the determinism contract — do not
    // reorder without accepting that every existing (seed, idx) replay changes meaning.
    private static final String[] STRUCT_FIELDS = {
        "nonce", "gasPrice", "gasLimit", "to", "value", "data", "chainId", "signature"
    };
    private static final int TX_FIELD_COUNT = 7;

    private Web3FuzzGenerator() {}

    /** validate <strategy>: struct | bytes | both. Throws IllegalArgumentException otherwise,
     * turned into the documented non-zero-exit-plus-stderr contract by the caller (main). */
    static void validateStrategy(String strategy) {
        if (!"struct".equals(strategy) && !"bytes".equals(strategy) && !"both".equals(strategy)) {
            throw new IllegalArgumentException(
                    "unknown web3fuzz strategy '"
                            + strategy
                            + "'; expected one of: struct, bytes, both");
        }
    }

    /** generate <count> mutant TSV lines for (seed, strategy). Pure function of its three
     * arguments (plus the fixed private key / chain id) — see class doc DETERMINISM CONTRACT. */
    static List<String> generate(int count, long seed, String strategy) {
        validateStrategy(strategy);
        if (count < 0) {
            throw new IllegalArgumentException("count must be >= 0, got " + count);
        }
        Random rng = new Random(seed);
        Credentials credentials = Credentials.create(FIXED_PRIVATE_KEY_HEX);
        List<String> lines = new ArrayList<>(count);
        for (int idx = 0; idx < count; idx++) {
            String kind = strategy;
            if ("both".equals(strategy)) {
                kind = rng.nextBoolean() ? "struct" : "bytes";
            }
            Mutant m =
                    "struct".equals(kind)
                            ? generateStructMutant(rng, credentials)
                            : generateBytesMutant(rng, credentials);
            lines.add(idx + "\t" + m.kind + "\t" + m.detail + "\t" + m.hex);
        }
        return lines;
    }

    /** web3fuzz --selfcheck: assert determinism (same (count,seed,strategy) twice -> identical
     * output) and that struct-kind lines round-trip decode via TransactionDecoder (bytes-kind
     * lines are allowed to be undecodable — that is the point of byte-level mutation). All output
     * goes to stderr, same convention as FuzzGenerator.selfCheck. */
    static boolean selfCheck() {
        boolean ok = true;
        try {
            List<String> run1 = generate(20, 12345L, "both");
            List<String> run2 = generate(20, 12345L, "both");
            boolean deterministic = run1.equals(run2);
            ok &=
                    report(
                            "determinism",
                            deterministic,
                            "generate(20,12345,both) run twice: "
                                    + run1.size()
                                    + "/"
                                    + run2.size()
                                    + " lines, "
                                    + (deterministic ? "byte-identical" : "DIFFERING"));

            int structTotal = 0, structDecoded = 0, bytesTotal = 0, badShape = 0;
            for (String line : run1) {
                String[] cols = line.split("\t", -1);
                if (cols.length != 4) {
                    badShape++;
                    continue;
                }
                String kind = cols[1];
                String hex = cols[3];
                if ("struct".equals(kind)) {
                    structTotal++;
                    try {
                        TransactionDecoder.decode(hex);
                        structDecoded++;
                    } catch (Exception e) {
                        // counted via structDecoded < structTotal below
                    }
                } else if ("bytes".equals(kind)) {
                    bytesTotal++;
                } else {
                    badShape++;
                }
            }
            ok &=
                    report(
                            "line_shape",
                            badShape == 0,
                            badShape + " lines with a bad TSV shape (expect 0)");
            ok &=
                    report(
                            "struct_round_trip",
                            structTotal > 0 && structDecoded == structTotal,
                            structDecoded
                                    + "/"
                                    + structTotal
                                    + " struct-kind lines decoded back via TransactionDecoder"
                                    + " (expect all)");
            report(
                    "bytes_present",
                    true,
                    bytesTotal + " bytes-kind lines observed (undecodable is fine, not scored)");
        } catch (Exception e) {
            System.err.println("WEB3FUZZ SELFCHECK ERROR: " + e);
            e.printStackTrace();
            return false;
        }
        return ok;
    }

    private static boolean report(String name, boolean pass, String detail) {
        System.err.println((pass ? "PASS" : "FAIL") + ": web3fuzz-selfcheck[" + name + "]: " + detail);
        return pass;
    }

    // -------------------------------------------------------------------------------------------
    // struct strategy
    // -------------------------------------------------------------------------------------------

    /** Build a base legacy RawTransaction, pick one of STRUCT_FIELDS, mutate it. Fields index <
     * TX_FIELD_COUNT additionally draw a reSign boolean: true re-signs over the mutated
     * transaction (a validly-signed-over-boundary-value tx — is the field-level VALUE what the
     * node's payload validation rejects); false keeps the signature computed over the
     * PRE-mutation transaction (a tx whose fields no longer match what was signed — breaks the
     * signature binding, same illegal_to/oob_field-vs-bad_signature axis FuzzGenerator draws for
     * TransactionData fields). "chainId" is not a RawTransaction field but a signing parameter;
     * see mutateChainId's own doc for how its reSign=false case is realized. "signature" mutates
     * v/r/s directly on an already validly-signed transaction — there is no reSign axis for it. */
    private static Mutant generateStructMutant(Random r, Credentials credentials) {
        BigInteger nonce = randomNonce(r);
        RawTransaction baseTx =
                RawTransaction.createTransaction(
                        nonce, GAS_PRICE, GAS_LIMIT, DEFAULT_TO, BigInteger.ZERO, DEFAULT_DATA_HEX);

        int fieldIdx = r.nextInt(STRUCT_FIELDS.length);
        String field = STRUCT_FIELDS[fieldIdx];
        String hex;
        String detail;
        if (fieldIdx < TX_FIELD_COUNT) {
            boolean reSign = r.nextBoolean();
            if ("chainId".equals(field)) {
                long mutatedChainId = randomChainId(r);
                if (reSign) {
                    byte[] signed = TransactionEncoder.signMessage(baseTx, mutatedChainId, credentials);
                    hex = Numeric.toHexString(signed);
                } else {
                    // Sign the UNMUTATED tx under the real CHAIN_ID to get a genuine r/s, then
                    // recompute v to CLAIM a different chain while keeping that r/s — an
                    // internally-inconsistent "wrong chain" signature, not a fresh valid one.
                    byte[] origSigned = TransactionEncoder.signMessage(baseTx, CHAIN_ID, credentials);
                    SignedRawTransaction decoded =
                            (SignedRawTransaction) TransactionDecoder.decode(Numeric.toHexString(origSigned));
                    Sign.SignatureData staleSig =
                            withClaimedChainId(decoded.getSignatureData(), CHAIN_ID, mutatedChainId);
                    hex = Numeric.toHexString(TransactionEncoder.encode(baseTx, staleSig));
                }
                detail = "chainId=" + mutatedChainId + ",resigned=" + (reSign ? 1 : 0);
            } else {
                MutatedField mf = mutateTxField(field, baseTx, r);
                if (reSign) {
                    hex = Numeric.toHexString(TransactionEncoder.signMessage(mf.rawTx, CHAIN_ID, credentials));
                } else {
                    byte[] origSigned = TransactionEncoder.signMessage(baseTx, CHAIN_ID, credentials);
                    SignedRawTransaction decoded =
                            (SignedRawTransaction) TransactionDecoder.decode(Numeric.toHexString(origSigned));
                    hex =
                            Numeric.toHexString(
                                    TransactionEncoder.encode(mf.rawTx, decoded.getSignatureData()));
                }
                detail = mf.detail + ",resigned=" + (reSign ? 1 : 0);
            }
        } else {
            byte[] signed = TransactionEncoder.signMessage(baseTx, CHAIN_ID, credentials);
            SignedRawTransaction decoded =
                    (SignedRawTransaction) TransactionDecoder.decode(Numeric.toHexString(signed));
            SigMutation sm = mutateSignature(decoded.getSignatureData(), r);
            hex = Numeric.toHexString(TransactionEncoder.encode(baseTx, sm.sig));
            detail = sm.detail + ",resigned=0";
        }
        return new Mutant("struct", detail, hex);
    }

    private static MutatedField mutateTxField(String field, RawTransaction base, Random r) {
        switch (field) {
            case "nonce":
                return mutateNonce(base, r);
            case "gasPrice":
                return mutateGasPrice(base, r);
            case "gasLimit":
                return mutateGasLimit(base, r);
            case "to":
                return mutateTo(base, r);
            case "value":
                return mutateValue(base, r);
            case "data":
                return mutateData(base, r);
            default:
                throw new IllegalStateException("not a mutable RawTransaction field: " + field);
        }
    }

    private static MutatedField mutateNonce(RawTransaction base, Random r) {
        BigInteger v;
        String label;
        int c = r.nextInt(3);
        switch (c) {
            case 0:
                v = BigInteger.ZERO;
                label = "ZERO";
                break;
            case 1:
                v = MAX_UINT256;
                label = "MAX_UINT256";
                break;
            default:
                v = randomNonce(r);
                label = "random(" + v + ")";
                break;
        }
        RawTransaction tx =
                RawTransaction.createTransaction(
                        v, base.getGasPrice(), base.getGasLimit(), base.getTo(), base.getValue(), base.getData());
        return new MutatedField(tx, "nonce=" + label);
    }

    private static MutatedField mutateGasPrice(RawTransaction base, Random r) {
        BigInteger v;
        String label;
        int c = r.nextInt(3);
        switch (c) {
            case 0:
                v = BigInteger.ZERO;
                label = "ZERO";
                break;
            case 1:
                v = MAX_UINT256;
                label = "MAX_UINT256";
                break;
            default:
                v = new BigInteger(32, r);
                label = "random_big";
                break;
        }
        RawTransaction tx =
                RawTransaction.createTransaction(
                        base.getNonce(), v, base.getGasLimit(), base.getTo(), base.getValue(), base.getData());
        return new MutatedField(tx, "gasPrice=" + label);
    }

    private static MutatedField mutateGasLimit(RawTransaction base, Random r) {
        BigInteger v;
        String label;
        int c = r.nextInt(3);
        switch (c) {
            case 0:
                v = BigInteger.ZERO;
                label = "ZERO";
                break;
            case 1:
                v = MAX_UINT256;
                label = "MAX_UINT256";
                break;
            default:
                v = new BigInteger(32, r);
                label = "random_big";
                break;
        }
        RawTransaction tx =
                RawTransaction.createTransaction(
                        base.getNonce(), base.getGasPrice(), v, base.getTo(), base.getValue(), base.getData());
        return new MutatedField(tx, "gasLimit=" + label);
    }

    private static MutatedField mutateTo(RawTransaction base, Random r) {
        String v;
        String label;
        int c = r.nextInt(3);
        switch (c) {
            case 0:
                v = "";
                label = "empty(contract-creation-shaped)";
                break;
            case 1:
                v = "0x1234"; // 2 bytes, not the required 20-byte address
                label = "short2bytes";
                break;
            default:
                int len = 1 + r.nextInt(60);
                v = randomHex(r, len);
                label = "random_len_" + len + "bytes";
                break;
        }
        RawTransaction tx =
                RawTransaction.createTransaction(
                        base.getNonce(), base.getGasPrice(), base.getGasLimit(), v, base.getValue(), base.getData());
        return new MutatedField(tx, "to=" + label);
    }

    private static MutatedField mutateValue(RawTransaction base, Random r) {
        BigInteger v;
        String label;
        int c = r.nextInt(3);
        switch (c) {
            case 0:
                v = BigInteger.ZERO;
                label = "ZERO";
                break;
            case 1:
                v = MAX_UINT256;
                label = "MAX_UINT256";
                break;
            default:
                v = new BigInteger(64, r);
                label = "random_big";
                break;
        }
        RawTransaction tx =
                RawTransaction.createTransaction(
                        base.getNonce(), base.getGasPrice(), base.getGasLimit(), base.getTo(), v, base.getData());
        return new MutatedField(tx, "value=" + label);
    }

    private static MutatedField mutateData(RawTransaction base, Random r) {
        int c = r.nextInt(2);
        int len = c == 0 ? r.nextInt(64) : 100_000 + r.nextInt(400_000);
        String v = randomHex(r, len);
        RawTransaction tx =
                RawTransaction.createTransaction(
                        base.getNonce(), base.getGasPrice(), base.getGasLimit(), base.getTo(), base.getValue(), v);
        return new MutatedField(tx, "data=" + (c == 0 ? "small_" : "large_") + len + "bytes");
    }

    private static long randomChainId(Random r) {
        int c = r.nextInt(4);
        switch (c) {
            case 0:
                return 0L;
            case 1:
                return 1L; // Ethereum mainnet — plausible "wrong but real-looking" chain id
            case 2:
                return Long.MAX_VALUE;
            default:
                return r.nextLong() & Long.MAX_VALUE; // keep non-negative: chainId is unsigned
        }
    }

    /** Recompute an EIP-155 v to CLAIM `claimedChainId` while keeping r/s from a signature that
     * was actually produced under `signedUnderChainId` — the recovery id is invariant across this
     * transform (v = recId + chainId*2 + 35), so it is simply extracted from the original v and
     * reapplied against the new chain id. The result is a structurally well-formed signature
     * (still RLP-decodable) that is cryptographically inconsistent: r/s prove
     * `signedUnderChainId`, v claims `claimedChainId`. */
    private static Sign.SignatureData withClaimedChainId(
            Sign.SignatureData sig, long signedUnderChainId, long claimedChainId) {
        BigInteger origV = new BigInteger(1, sig.getV());
        BigInteger recId = origV.subtract(BigInteger.valueOf(signedUnderChainId * 2 + 35));
        BigInteger newV = recId.add(BigInteger.valueOf(claimedChainId * 2 + 35));
        return new Sign.SignatureData(newV.toByteArray(), sig.getR(), sig.getS());
    }

    private static SigMutation mutateSignature(Sign.SignatureData sig, Random r) {
        int which = r.nextInt(3);
        switch (which) {
            case 0:
                {
                    byte[] newV = randomBytes(r, 1 + r.nextInt(3));
                    return new SigMutation(
                            new Sign.SignatureData(newV, sig.getR(), sig.getS()), "signature=v_mutated");
                }
            case 1:
                {
                    byte[] newR = randomBytes(r, 32);
                    return new SigMutation(
                            new Sign.SignatureData(sig.getV(), newR, sig.getS()), "signature=r_mutated");
                }
            default:
                {
                    byte[] newS = randomBytes(r, 32);
                    return new SigMutation(
                            new Sign.SignatureData(sig.getV(), sig.getR(), newS), "signature=s_mutated");
                }
        }
    }

    // -------------------------------------------------------------------------------------------
    // bytes strategy
    // -------------------------------------------------------------------------------------------

    /** Build a base, validly-signed tx (same recipe as generateStructMutant's base build — fixed
     * chain id, fixed key, seeded random nonce) and apply exactly one random byte-level op to its
     * raw signed-RLP bytes. This mostly produces RLP-undecodable garbage; that is the point (it
     * fuzzes the Web3 RPC's RLP decoder rather than the field-level validators struct mutation
     * targets). */
    private static Mutant generateBytesMutant(Random r, Credentials credentials) {
        BigInteger nonce = randomNonce(r);
        RawTransaction baseTx =
                RawTransaction.createTransaction(
                        nonce, GAS_PRICE, GAS_LIMIT, DEFAULT_TO, BigInteger.ZERO, DEFAULT_DATA_HEX);
        byte[] raw = TransactionEncoder.signMessage(baseTx, CHAIN_ID, credentials);

        int op = r.nextInt(5);
        ByteMutation m;
        switch (op) {
            case 0:
                m = opFlip(raw, r);
                break;
            case 1:
                m = opInsert(raw, r);
                break;
            case 2:
                m = opDelete(raw, r);
                break;
            case 3:
                m = opTruncate(raw, r);
                break;
            default:
                m = opDuplicate(raw, r);
                break;
        }
        return new Mutant("bytes", m.detail, Numeric.toHexString(m.bytes));
    }

    private static ByteMutation opFlip(byte[] raw, Random r) {
        if (raw.length == 0) {
            return new ByteMutation(raw.clone(), "flip:noop_empty");
        }
        int n = 1 + r.nextInt(Math.min(5, raw.length));
        byte[] mutated = raw.clone();
        StringBuilder offsets = new StringBuilder();
        for (int i = 0; i < n; i++) {
            int off = r.nextInt(mutated.length);
            mutated[off] ^= (byte) (1 + r.nextInt(255));
            if (i > 0) {
                offsets.append(';');
            }
            offsets.append(off);
        }
        return new ByteMutation(mutated, "flip:n=" + n + ",offsets=" + offsets);
    }

    private static ByteMutation opInsert(byte[] raw, Random r) {
        int pos = raw.length == 0 ? 0 : r.nextInt(raw.length + 1);
        int len = 1 + r.nextInt(20);
        byte[] ins = randomBytes(r, len);
        return new ByteMutation(insertAt(raw, pos, ins), "insert:offset=" + pos + ",len=" + len);
    }

    private static ByteMutation opDelete(byte[] raw, Random r) {
        if (raw.length == 0) {
            return new ByteMutation(raw.clone(), "delete:noop_empty");
        }
        int start = r.nextInt(raw.length);
        int len = 1 + r.nextInt(raw.length - start);
        return new ByteMutation(deleteRange(raw, start, len), "delete:offset=" + start + ",len=" + len);
    }

    private static ByteMutation opTruncate(byte[] raw, Random r) {
        int cut = raw.length == 0 ? 0 : r.nextInt(raw.length);
        return new ByteMutation(Arrays.copyOf(raw, cut), "truncate:len=" + cut);
    }

    private static ByteMutation opDuplicate(byte[] raw, Random r) {
        if (raw.length == 0) {
            return new ByteMutation(raw.clone(), "duplicate:noop_empty");
        }
        int start = r.nextInt(raw.length);
        int len = 1 + r.nextInt(raw.length - start);
        byte[] range = Arrays.copyOfRange(raw, start, start + len);
        return new ByteMutation(
                insertAt(raw, start + len, range), "duplicate:offset=" + start + ",len=" + len);
    }

    private static byte[] insertAt(byte[] src, int pos, byte[] insert) {
        byte[] out = new byte[src.length + insert.length];
        System.arraycopy(src, 0, out, 0, pos);
        System.arraycopy(insert, 0, out, pos, insert.length);
        System.arraycopy(src, pos, out, pos + insert.length, src.length - pos);
        return out;
    }

    private static byte[] deleteRange(byte[] src, int start, int len) {
        byte[] out = new byte[src.length - len];
        System.arraycopy(src, 0, out, 0, start);
        System.arraycopy(src, start + len, out, start, src.length - start - len);
        return out;
    }

    // -------------------------------------------------------------------------------------------
    // shared helpers
    // -------------------------------------------------------------------------------------------

    private static BigInteger randomNonce(Random r) {
        return BigInteger.valueOf(r.nextLong() & Long.MAX_VALUE);
    }

    private static byte[] randomBytes(Random r, int len) {
        byte[] b = new byte[len];
        r.nextBytes(b);
        return b;
    }

    private static String randomHex(Random r, int lenBytes) {
        return Numeric.toHexString(randomBytes(r, lenBytes));
    }

    private static final class Mutant {
        final String kind;
        final String detail;
        final String hex;

        Mutant(String kind, String detail, String hex) {
            this.kind = kind;
            this.detail = detail;
            this.hex = hex;
        }
    }

    private static final class MutatedField {
        final RawTransaction rawTx;
        final String detail;

        MutatedField(RawTransaction rawTx, String detail) {
            this.rawTx = rawTx;
            this.detail = detail;
        }
    }

    private static final class SigMutation {
        final Sign.SignatureData sig;
        final String detail;

        SigMutation(Sign.SignatureData sig, String detail) {
            this.sig = sig;
            this.detail = detail;
        }
    }

    private static final class ByteMutation {
        final byte[] bytes;
        final String detail;

        ByteMutation(byte[] bytes, String detail) {
            this.bytes = bytes;
            this.detail = detail;
        }
    }
}
