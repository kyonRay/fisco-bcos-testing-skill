package fisco.tamperfuzz;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Random;
import java.util.function.Consumer;
import org.fisco.bcos.sdk.jni.common.JniException;
import org.fisco.bcos.sdk.jni.utilities.tx.Transaction;
import org.fisco.bcos.sdk.jni.utilities.tx.TransactionBuilderJniObj;
import org.fisco.bcos.sdk.jni.utilities.tx.TransactionData;
import org.fisco.bcos.sdk.jni.utilities.tx.TransactionStructBuilderJniObj;
import org.fisco.bcos.sdk.v3.crypto.CryptoSuite;
import org.fisco.bcos.sdk.v3.crypto.keypair.CryptoKeyPair;
import org.fisco.bcos.sdk.v3.model.CryptoType;

/**
 * FuzzGenerator — open-seed mutation generator for the release-gate BCOS-RPC fuzz driver
 * (scripts/fuzz_bcos.sh). Invoked as `java -jar tamper-fuzz-all.jar fuzz <count> <seed>
 * <strategy>`, strategy in {struct, bytes, both}. Prints <count> TSV lines to stdout:
 * `<idx>\t<kind>\t<detail>\t<hex>`, kind in {struct, bytes}, hex the mutant raw tx (0x-prefixed).
 * idx is 0..count-1. No other stdout — callers (fuzz_bcos.sh) read column 4 for the hex to
 * inject and columns 1-3 for logging only.
 *
 * Unlike TamperFuzz's three directed cases (which sign with a fresh random keypair per process —
 * fine there, since those cases are re-derived fresh on every scenario_malformed.sh run and never
 * need to replay byte-identical), this generator signs with a FIXED hardcoded test private key
 * (see FIXED_PRIVATE_KEY_HEX below) so re-running the same (count, seed, strategy) reproduces the
 * identical signature bytes too — that is load-bearing for fuzz_bcos.sh's bisection, which
 * replays a single (seed, idx) to isolate the mutant that tripped an oracle.
 *
 * DETERMINISM CONTRACT: exactly one java.util.Random(seed) drives every choice this class makes —
 * which strategy an idx gets (for "both"), which struct field or byte op is mutated, every
 * boundary/random value, every byte offset/length. Every draw happens in a FIXED sequence (idx
 * 0..count-1 in order, and within each idx a fixed call order — see generateStructMutant /
 * generateBytesMutant), so the same (count, seed, strategy) always replays the exact same
 * sequence of Random draws and therefore byte-identical output. Do NOT introduce
 * System.nanoTime()/System.currentTimeMillis()/SecureRandom/HashMap (or HashSet) iteration order,
 * or any other non-seed-derived source of variation anywhere in this class — `fuzz --selfcheck`
 * asserts this by generating the same corpus twice and diffing.
 */
final class FuzzGenerator {

    // Fixed test private key (secp256k1, 32 bytes) — a well-known throwaway dev key (Hardhat's
    // default account #0), reused here only for its property of being a stable constant, never
    // for any live-chain identity. Never send funds to or otherwise trust an address derived from
    // this key.
    private static final String FIXED_PRIVATE_KEY_HEX =
            "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

    private static final int TX_ATTRIBUTE = 0;

    // TransactionData fields first (indices 0..TD_FIELD_COUNT-1), envelope (Transaction) fields
    // after. Order is part of the determinism contract — do not reorder without accepting that
    // every existing (seed, idx) replay changes meaning.
    private static final String[] STRUCT_FIELDS = {
        "to", "blockLimit", "nonce", "chainId", "groupId", "version", "input",
        "signature", "sender", "dataHash", "importTime", "attribute"
    };
    private static final int TD_FIELD_COUNT = 7;

    private static final String ALNUM =
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    private static final String DIGITS = "0123456789";

    private FuzzGenerator() {}

    /** validate <strategy>: struct | bytes | both. Throws IllegalArgumentException otherwise,
     * turned into the documented non-zero-exit-plus-stderr contract by the caller (main). */
    static void validateStrategy(String strategy) {
        if (!"struct".equals(strategy) && !"bytes".equals(strategy) && !"both".equals(strategy)) {
            throw new IllegalArgumentException(
                    "unknown fuzz strategy '"
                            + strategy
                            + "'; expected one of: struct, bytes, both");
        }
    }

    /** generate <count> mutant TSV lines for (seed, strategy). Pure function of its three
     * arguments (plus the fixed private key / crypto type) — see class doc DETERMINISM
     * CONTRACT. */
    static List<String> generate(int count, long seed, String strategy) throws JniException {
        validateStrategy(strategy);
        if (count < 0) {
            throw new IllegalArgumentException("count must be >= 0, got " + count);
        }
        Random rng = new Random(seed);
        CryptoSuite suite = fixedCryptoSuite();
        List<String> lines = new ArrayList<>(count);
        for (int idx = 0; idx < count; idx++) {
            String kind = strategy;
            if ("both".equals(strategy)) {
                kind = rng.nextBoolean() ? "struct" : "bytes";
            }
            Mutant m =
                    "struct".equals(kind)
                            ? generateStructMutant(rng, suite)
                            : generateBytesMutant(rng, suite);
            lines.add(idx + "\t" + m.kind + "\t" + m.detail + "\t" + m.hex);
        }
        return lines;
    }

    /** fuzz --selfcheck: assert determinism (same (count,seed,strategy) twice -> identical
     * output) and that struct-kind lines round-trip decode (bytes-kind lines are allowed to be
     * undecodable — that is the point of byte-level mutation). All output goes to stderr, same
     * convention as TamperFuzz.SelfCheck. */
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
                        TransactionStructBuilderJniObj.decodeTransactionStruct(hex);
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
            ok &= report("line_shape", badShape == 0, badShape + " lines with a bad TSV shape (expect 0)");
            ok &=
                    report(
                            "struct_round_trip",
                            structTotal > 0 && structDecoded == structTotal,
                            structDecoded + "/" + structTotal + " struct-kind lines decoded back to a Transaction (expect all)");
            report(
                    "bytes_present",
                    true,
                    bytesTotal + " bytes-kind lines observed (undecodable is fine, not scored)");
        } catch (Exception e) {
            System.err.println("FUZZ SELFCHECK ERROR: " + e);
            e.printStackTrace();
            return false;
        }
        return ok;
    }

    private static boolean report(String name, boolean pass, String detail) {
        System.err.println((pass ? "PASS" : "FAIL") + ": fuzz-selfcheck[" + name + "]: " + detail);
        return pass;
    }

    // -------------------------------------------------------------------------------------------
    // struct strategy
    // -------------------------------------------------------------------------------------------

    /** Build a base TransactionData, pick one of STRUCT_FIELDS, mutate it. TransactionData
     * fields (index < TD_FIELD_COUNT) additionally draw a reSign boolean: true re-signs over the
     * mutated data (validly-signed-over-garbage, the illegal_to/oob_field recipe), false keeps
     * the signature/dataHash computed over the PRE-mutation data (garbage that also breaks the
     * signature binding). Envelope fields (signature/sender/dataHash/importTime/attribute) are
     * mutated directly on an already validly-signed Transaction — there is no "re-sign" axis for
     * them, mirroring the bad_signature case's own decode -> mutate -> re-encode recipe. */
    private static Mutant generateStructMutant(Random r, CryptoSuite suite) throws JniException {
        TransactionData td = TamperFuzz.buildBaseTransactionData();
        // Always overwrite the nonce from our seeded RNG (even when nonce isn't the field being
        // targeted this round) — buildBaseTransactionData()'s underlying native call is not
        // proven to be seed-derived itself, so this is the belt that guarantees byte-identical
        // output regardless of what that native helper does internally.
        td.setNonce(randomHexNoPrefix(r, 16));

        int fieldIdx = r.nextInt(STRUCT_FIELDS.length);
        String field = STRUCT_FIELDS[fieldIdx];
        String hex;
        String detail;
        if (fieldIdx < TD_FIELD_COUNT) {
            CryptoKeyPair kp = suite.getCryptoKeyPair();
            String origHash =
                    TransactionStructBuilderJniObj.calcTransactionDataStructHash(
                            suite.getCryptoTypeConfig(), td);
            String origSig =
                    TransactionBuilderJniObj.signTransactionDataHash(kp.getJniKeyPair(), origHash);
            boolean reSign = r.nextBoolean();
            String mutation = mutateTdField(field, td, r);
            if (reSign) {
                hex = TamperFuzz.signAndAssemble(td, suite);
            } else {
                hex =
                        TransactionStructBuilderJniObj.createEncodedTransaction(
                                td, origSig, origHash, TX_ATTRIBUTE, "");
            }
            detail = mutation + ",resigned=" + (reSign ? 1 : 0);
        } else {
            String goodHex = TamperFuzz.signAndAssemble(td, suite);
            Transaction tx = TransactionStructBuilderJniObj.decodeTransactionStruct(goodHex);
            detail = mutateEnvelopeField(field, tx, r);
            hex = TransactionStructBuilderJniObj.encodeTransactionStruct(tx);
        }
        return new Mutant("struct", detail, hex);
    }

    private static String mutateTdField(String field, TransactionData td, Random r) {
        switch (field) {
            case "to":
                return mutateTo(td, r);
            case "blockLimit":
                return mutateBlockLimit(td, r);
            case "nonce":
                return mutateNonce(td, r);
            case "chainId":
                return mutateIdField(r, td::setChainId, "chainId");
            case "groupId":
                return mutateIdField(r, td::setGroupId, "groupId");
            case "version":
                return mutateVersion(td, r);
            case "input":
                return mutateInput(td, r);
            default:
                throw new IllegalStateException("not a TransactionData field: " + field);
        }
    }

    private static String mutateEnvelopeField(String field, Transaction tx, Random r) {
        switch (field) {
            case "signature":
                return mutateSignature(tx, r);
            case "sender":
                return mutateSender(tx, r);
            case "dataHash":
                return mutateDataHash(tx, r);
            case "importTime":
                return mutateImportTime(tx, r);
            case "attribute":
                return mutateAttribute(tx, r);
            default:
                throw new IllegalStateException("not an envelope field: " + field);
        }
    }

    private static String mutateTo(TransactionData td, Random r) {
        int v = r.nextInt(3);
        switch (v) {
            case 0:
                td.setTo("0x");
                return "to=empty";
            case 1:
                td.setTo(TamperFuzz.ILLEGAL_TO);
                return "to=short2bytes";
            default:
                int len = 1 + r.nextInt(100);
                td.setTo(randomHex(r, len));
                return "to=random_len_" + len + "bytes";
        }
    }

    private static String mutateBlockLimit(TransactionData td, Random r) {
        int v = r.nextInt(5);
        long val;
        String label;
        switch (v) {
            case 0:
                val = Long.MIN_VALUE;
                label = "MIN";
                break;
            case 1:
                val = Long.MAX_VALUE;
                label = "MAX";
                break;
            case 2:
                val = 0L;
                label = "ZERO";
                break;
            case 3:
                val = -1L;
                label = "NEG1";
                break;
            default:
                val = r.nextLong();
                label = "random(" + val + ")";
                break;
        }
        td.setBlockLimit(val);
        return "blockLimit=" + label;
    }

    private static String mutateNonce(TransactionData td, Random r) {
        int v = r.nextInt(3);
        switch (v) {
            case 0:
                int hugeLen = 50 + r.nextInt(200);
                td.setNonce(randomDigits(r, hugeLen));
                return "nonce=huge_numeric_" + hugeLen;
            case 1:
                td.setNonce("");
                return "nonce=empty";
            default:
                int len = 1 + r.nextInt(40);
                td.setNonce(randomAlnum(r, len));
                return "nonce=non_numeric_" + len;
        }
    }

    private static String mutateIdField(Random r, Consumer<String> setter, String fieldName) {
        int v = r.nextInt(3);
        switch (v) {
            case 0:
                int len = 1 + r.nextInt(30);
                setter.accept(randomAlnum(r, len));
                return fieldName + "=random_" + len;
            case 1:
                setter.accept("");
                return fieldName + "=empty";
            default:
                int longLen = 500 + r.nextInt(1500);
                setter.accept(randomAlnum(r, longLen));
                return fieldName + "=very_long_" + longLen;
        }
    }

    private static String mutateVersion(TransactionData td, Random r) {
        int v = r.nextInt(4);
        switch (v) {
            case 0:
                td.setVersion(Integer.MIN_VALUE);
                return "version=MIN";
            case 1:
                td.setVersion(Integer.MAX_VALUE);
                return "version=MAX";
            case 2:
                int neg = -(1 + r.nextInt(1000000));
                td.setVersion(neg);
                return "version=negative(" + neg + ")";
            default:
                int huge = 1000000 + r.nextInt(Integer.MAX_VALUE - 1000000);
                td.setVersion(huge);
                return "version=huge(" + huge + ")";
        }
    }

    private static String mutateInput(TransactionData td, Random r) {
        int v = r.nextInt(2);
        int len = v == 0 ? r.nextInt(64) : 100000 + r.nextInt(400000);
        td.setInput(randomBytes(r, len));
        return "input=" + (v == 0 ? "small_" : "large_") + len + "bytes";
    }

    private static String mutateSignature(Transaction tx, Random r) {
        int v = r.nextInt(3);
        switch (v) {
            case 0:
                tx.setSignature(new byte[0]);
                return "signature=empty";
            case 1:
                int oversized = 65 + r.nextInt(136);
                tx.setSignature(randomBytes(r, oversized));
                return "signature=oversized_" + oversized;
            default:
                int shortLen = 1 + r.nextInt(30);
                tx.setSignature(randomBytes(r, shortLen));
                return "signature=short_" + shortLen;
        }
    }

    private static String mutateSender(Transaction tx, Random r) {
        // Correct sender length is 20 bytes (an address); both branches always land off that.
        int v = r.nextInt(2);
        int len = v == 0 ? r.nextInt(20) : 21 + r.nextInt(44);
        tx.setSender(randomBytes(r, len));
        return "sender=wrong_length_" + len;
    }

    private static String mutateDataHash(Transaction tx, Random r) {
        int v = r.nextInt(2);
        if (v == 0) {
            tx.setDataHash(randomBytes(r, 32));
            return "dataHash=random32";
        }
        int len = r.nextInt(64);
        if (len == 32) {
            len = 33; // keep this branch genuinely "wrong length", not accidentally 32
        }
        tx.setDataHash(randomBytes(r, len));
        return "dataHash=wrong_length_" + len;
    }

    private static String mutateImportTime(Transaction tx, Random r) {
        int v = r.nextInt(2);
        long val = v == 0 ? (Long.MIN_VALUE + r.nextInt(1000000)) : Long.MAX_VALUE;
        tx.setImportTime(val);
        return "importTime=" + (v == 0 ? "negative" : "MAX");
    }

    private static String mutateAttribute(Transaction tx, Random r) {
        int val = r.nextInt();
        tx.setAttribute(val);
        return "attribute=random(" + val + ")";
    }

    // -------------------------------------------------------------------------------------------
    // bytes strategy
    // -------------------------------------------------------------------------------------------

    /** Build a base, validly-signed tx (same recipe as generateStructMutant's envelope branch —
     * fixed nonce override, fixed key) and apply exactly one random byte-level op to its raw
     * bytes. This mostly produces tars-undecodable garbage; that is the point (it fuzzes the
     * decoder/parser rather than the field-level validators struct mutation targets). */
    private static Mutant generateBytesMutant(Random r, CryptoSuite suite) throws JniException {
        TransactionData td = TamperFuzz.buildBaseTransactionData();
        td.setNonce(randomHexNoPrefix(r, 16));
        String hex = TamperFuzz.signAndAssemble(td, suite);
        byte[] raw = hexToBytes(hex);

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
        return new Mutant("bytes", m.detail, bytesToHex(m.bytes));
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
            // XOR with a nonzero random mask so the byte is guaranteed to actually change (a
            // "flip", not a no-op).
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

    private static CryptoSuite fixedCryptoSuite() {
        int cryptoType = CryptoType.ECDSA_TYPE;
        String envType = System.getenv("TAMPER_CRYPTO_TYPE");
        if (envType != null && !envType.trim().isEmpty()) {
            cryptoType = Integer.parseInt(envType.trim());
        }
        return new CryptoSuite(cryptoType, FIXED_PRIVATE_KEY_HEX);
    }

    private static byte[] randomBytes(Random r, int len) {
        byte[] b = new byte[len];
        r.nextBytes(b);
        return b;
    }

    private static String randomHex(Random r, int lenBytes) {
        return "0x" + bytesToHexNoPrefix(randomBytes(r, lenBytes));
    }

    private static String randomHexNoPrefix(Random r, int lenBytes) {
        return bytesToHexNoPrefix(randomBytes(r, lenBytes));
    }

    private static String randomAlnum(Random r, int len) {
        StringBuilder sb = new StringBuilder(len);
        for (int i = 0; i < len; i++) {
            sb.append(ALNUM.charAt(r.nextInt(ALNUM.length())));
        }
        return sb.toString();
    }

    private static String randomDigits(Random r, int len) {
        StringBuilder sb = new StringBuilder(len);
        for (int i = 0; i < len; i++) {
            sb.append(DIGITS.charAt(r.nextInt(DIGITS.length())));
        }
        return sb.toString();
    }

    private static byte[] hexToBytes(String hex) {
        String h = (hex.startsWith("0x") || hex.startsWith("0X")) ? hex.substring(2) : hex;
        if ((h.length() % 2) != 0) {
            h = "0" + h;
        }
        int len = h.length() / 2;
        byte[] out = new byte[len];
        for (int i = 0; i < len; i++) {
            out[i] = (byte) Integer.parseInt(h.substring(i * 2, i * 2 + 2), 16);
        }
        return out;
    }

    private static String bytesToHexNoPrefix(byte[] b) {
        StringBuilder sb = new StringBuilder(b.length * 2);
        for (byte x : b) {
            sb.append(String.format("%02x", x));
        }
        return sb.toString();
    }

    private static String bytesToHex(byte[] b) {
        return "0x" + bytesToHexNoPrefix(b);
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

    private static final class ByteMutation {
        final byte[] bytes;
        final String detail;

        ByteMutation(byte[] bytes, String detail) {
            this.bytes = bytes;
            this.detail = detail;
        }
    }
}
