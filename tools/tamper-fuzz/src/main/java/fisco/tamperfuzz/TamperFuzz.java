package fisco.tamperfuzz;

import java.util.Arrays;
import org.fisco.bcos.sdk.jni.common.JniException;
import org.fisco.bcos.sdk.jni.utilities.tx.Transaction;
import org.fisco.bcos.sdk.jni.utilities.tx.TransactionBuilderJniObj;
import org.fisco.bcos.sdk.jni.utilities.tx.TransactionData;
import org.fisco.bcos.sdk.jni.utilities.tx.TransactionStructBuilderJniObj;
import org.fisco.bcos.sdk.v3.crypto.CryptoSuite;
import org.fisco.bcos.sdk.v3.crypto.keypair.CryptoKeyPair;
import org.fisco.bcos.sdk.v3.model.CryptoType;

/**
 * TamperFuzz — TAMPER_HELPER for scenario_malformed.sh. `java -jar tamper-fuzz-all.jar <case>`
 * prints one line of tampered raw tx hex to stdout (nothing else on stdout). Cases: illegal_to,
 * oob_field (validly-signed tx over a malformed TransactionData payload — signature must verify,
 * the malformed field is what the node's payload validation must reject) and bad_signature (a
 * well-formed envelope whose signature no longer matches its dataHash). See
 * ../../../scripts/scenarios/scenario_malformed.sh MAL_CASES for the exact case contract this
 * mirrors.
 */
public final class TamperFuzz {

    // Seed material for the base (pre-tamper) transaction. This tx is never sent to a real chain
    // by this tool — only the tampered hex it prints is, and only by the live scenario that shells
    // out to us.
    private static final String DEFAULT_TO = "0x1234567890123456789012345678901234567890";
    private static final String DEFAULT_INPUT_HEX = "deadbeef";
    // Fallback base blockLimit for offline use (e.g. --selfcheck) when TAMPER_BLOCK_LIMIT isn't
    // set. On a live chain this tool has no way to know the current block height itself — a fixed
    // constant here would almost certainly fall outside the live blockLimit window, which made
    // illegal_to a false-green (rejected as BlockLimitCheckFail before the node ever reached `to`
    // validation, since the node checks signature -> blockLimit -> payload in that order). The
    // caller (tamper-helper.sh, against a live chain) must pass an in-window value via
    // TAMPER_BLOCK_LIMIT so illegal_to/bad_signature actually reach the validation they target.
    private static final long DEFAULT_BLOCK_LIMIT = 10000L;
    private static final int TX_ATTRIBUTE = 0;

    // The malformed values each case injects.
    static final String ILLEGAL_TO = "0x1234"; // 2 bytes, not the required 20-byte address
    static final long BAD_BLOCK_LIMIT = -1L; // negative blockLimit

    private TamperFuzz() {}

    public static void main(String[] args) {
        if (args.length == 1 && "--selfcheck".equals(args[0])) {
            System.exit(SelfCheck.run() ? 0 : 1);
            return;
        }
        if (args.length >= 1 && "fuzz".equals(args[0])) {
            System.exit(runFuzzMode(args) ? 0 : 1);
            return;
        }
        if (args.length != 1) {
            System.err.println(
                    "usage: java -jar tamper-fuzz-all.jar <illegal_to|oob_field|bad_signature>"
                            + " | --selfcheck"
                            + " | fuzz <count> <seed> <struct|bytes|both>"
                            + " | fuzz --selfcheck");
            System.exit(1);
            return;
        }
        try {
            String hex = tamper(args[0], newCryptoSuite());
            System.out.println(hex);
        } catch (IllegalArgumentException e) {
            System.err.println("ERROR: tamper-fuzz: " + e.getMessage());
            System.exit(1);
        } catch (Exception e) {
            System.err.println(
                    "ERROR: tamper-fuzz: unexpected failure producing case '"
                            + args[0]
                            + "': "
                            + e);
            e.printStackTrace();
            System.exit(1);
        }
    }

    /** `fuzz <count> <seed> <strategy>` — print <count> deterministic mutant TSV lines (see
     * FuzzGenerator's class doc). `fuzz --selfcheck` runs FuzzGenerator.selfCheck() instead
     * (determinism + struct round-trip assertions, output to stderr). Returns whether the
     * invocation succeeded (mirrors the process exit-code contract main() otherwise inlines). */
    private static boolean runFuzzMode(String[] args) {
        if (args.length == 2 && "--selfcheck".equals(args[1])) {
            return FuzzGenerator.selfCheck();
        }
        if (args.length != 4) {
            System.err.println(
                    "usage: java -jar tamper-fuzz-all.jar fuzz <count> <seed> <struct|bytes|both>"
                            + " | fuzz --selfcheck");
            return false;
        }
        try {
            int count = Integer.parseInt(args[1]);
            long seed = Long.parseLong(args[2]);
            String strategy = args[3];
            for (String line : FuzzGenerator.generate(count, seed, strategy)) {
                System.out.println(line);
            }
            return true;
        } catch (NumberFormatException e) {
            System.err.println(
                    "ERROR: tamper-fuzz: fuzz: <count> and <seed> must be integers: " + e.getMessage());
            return false;
        } catch (IllegalArgumentException e) {
            System.err.println("ERROR: tamper-fuzz: fuzz: " + e.getMessage());
            return false;
        } catch (Exception e) {
            System.err.println("ERROR: tamper-fuzz: fuzz: unexpected failure: " + e);
            e.printStackTrace();
            return false;
        }
    }

    /** Dispatch one case name to its tampered hex. Throws IllegalArgumentException on an unknown
     * case name — callers turn that into the documented non-zero-exit-plus-stderr contract. */
    static String tamper(String caseName, CryptoSuite suite) throws JniException {
        switch (caseName) {
            case "illegal_to":
                {
                    TransactionData td = buildBaseTransactionData();
                    td.setTo(ILLEGAL_TO);
                    return signAndAssemble(td, suite);
                }
            case "oob_field":
                {
                    TransactionData td = buildBaseTransactionData();
                    td.setBlockLimit(BAD_BLOCK_LIMIT);
                    return signAndAssemble(td, suite);
                }
            case "bad_signature":
                return buildBadSignatureCase(suite).badHex;
            default:
                throw new IllegalArgumentException(
                        "unknown case '"
                                + caseName
                                + "'; expected one of: illegal_to, oob_field, bad_signature");
        }
    }

    /** Build a well-formed TransactionData (proper random nonce etc.) via the pointer-based JNI
     * API, then hand back its struct-decoded POJO so callers can mutate individual fields (to,
     * blockLimit, ...) before re-signing. Frees the native pointer before returning. The base
     * blockLimit comes from {@link #baseBlockLimit()} — env-overridable so a live-chain caller can
     * hand in an in-window value (see DEFAULT_BLOCK_LIMIT's comment). oob_field overrides this
     * with its own bad value regardless; that override happens in {@link #tamper}, after this
     * method returns. */
    static TransactionData buildBaseTransactionData() throws JniException {
        long ptr =
                TransactionBuilderJniObj.createTransactionData(
                        groupId(), chainId(), DEFAULT_TO, DEFAULT_INPUT_HEX, "", baseBlockLimit());
        try {
            String txDataHex = TransactionBuilderJniObj.encodeTransactionData(ptr);
            return TransactionStructBuilderJniObj.decodeTransactionDataStruct(txDataHex);
        } finally {
            TransactionBuilderJniObj.destroyTransactionData(ptr);
        }
    }

    /** Base blockLimit for illegal_to / bad_signature / oob_field's own pre-tamper build: from env
     * TAMPER_BLOCK_LIMIT when set (a live caller should pass currentBlock + a safety margin),
     * else DEFAULT_BLOCK_LIMIT for offline use. */
    static long baseBlockLimit() {
        String v = System.getenv("TAMPER_BLOCK_LIMIT");
        if (v != null && !v.trim().isEmpty()) {
            return Long.parseLong(v.trim());
        }
        return DEFAULT_BLOCK_LIMIT;
    }

    /** Hash + sign a (possibly malformed) TransactionData struct and assemble the full encoded
     * signed transaction. The signature is always computed over whatever `td` currently holds, so
     * a caller who mutated `td` first (illegal_to / oob_field) gets a signature that verifies over
     * the malformed data — that is the point of those two cases. */
    static String signAndAssemble(TransactionData td, CryptoSuite suite) throws JniException {
        CryptoKeyPair kp = suite.getCryptoKeyPair();
        String dataHash =
                TransactionStructBuilderJniObj.calcTransactionDataStructHash(
                        suite.getCryptoTypeConfig(), td);
        String signature =
                TransactionBuilderJniObj.signTransactionDataHash(kp.getJniKeyPair(), dataHash);
        return TransactionStructBuilderJniObj.createEncodedTransaction(
                td, signature, dataHash, TX_ATTRIBUTE, "");
    }

    /** bad_signature: sign a well-formed TransactionData normally (goodHex), then decode -> zero
     * out the signature's r component (its first 32 bytes) -> re-encode (badHex). Data and
     * dataHash are untouched, only the signature bytes differ between goodHex and badHex — the
     * binding to the data is broken, not the data itself.
     *
     * Zeroing r rather than flipping one arbitrary byte is deliberate, not cosmetic: FISCO-BCOS
     * recovers the sender FROM the signature (ECDSA recoverable signatures, like Ethereum) rather
     * than checking it against a claimed sender. A single-byte flip usually still lands on a
     * mathematically valid (r, s, v) triple — it just recovers to a DIFFERENT pubkey/address, so
     * the node accepts it as a legitimately-signed tx from a junk sender. A live-chain run
     * confirmed this: flipping byte 0 was accepted 4 times out of 5, each with a different
     * recovered `from`, and rejected only once. r=0 is never a valid ECDSA signature (r must be a
     * nonzero field element), so recovery fails deterministically on every run, and the node
     * returns InvalidSignature every time — an actually-broken signature, not just a different
     * one. */
    static SignedPair buildBadSignatureCase(CryptoSuite suite) throws JniException {
        TransactionData td = buildBaseTransactionData();
        String goodHex = signAndAssemble(td, suite);
        Transaction tx = TransactionStructBuilderJniObj.decodeTransactionStruct(goodHex);
        byte[] sig = tx.getSignature();
        if (sig == null || sig.length == 0) {
            throw new IllegalStateException("decoded signature was empty; cannot corrupt it");
        }
        byte[] corrupted = sig.clone();
        java.util.Arrays.fill(corrupted, 0, Math.min(32, corrupted.length), (byte) 0);
        tx.setSignature(corrupted);
        String badHex = TransactionStructBuilderJniObj.encodeTransactionStruct(tx);
        return new SignedPair(goodHex, badHex);
    }

    static final class SignedPair {
        final String goodHex;
        final String badHex;

        SignedPair(String goodHex, String badHex) {
            this.goodHex = goodHex;
            this.badHex = badHex;
        }
    }

    static CryptoSuite newCryptoSuite() {
        int cryptoType = CryptoType.ECDSA_TYPE;
        String envType = System.getenv("TAMPER_CRYPTO_TYPE");
        if (envType != null && !envType.trim().isEmpty()) {
            cryptoType = Integer.parseInt(envType.trim());
        }
        return new CryptoSuite(cryptoType);
    }

    static String chainId() {
        String v = System.getenv("TAMPER_CHAIN_ID");
        return (v == null || v.isEmpty()) ? "chain0" : v;
    }

    static String groupId() {
        String v = System.getenv("TAMPER_GROUP_ID");
        return (v == null || v.isEmpty()) ? "group0" : v;
    }

    /** --selfcheck: round-trip-verify each case's tamper actually landed. All output goes to
     * stderr (this mode is a diagnostic, not part of the stdout-purity contract). */
    static final class SelfCheck {
        private SelfCheck() {}

        static boolean run() {
            boolean ok = true;
            try {
                CryptoSuite suite = newCryptoSuite();

                // illegal_to must carry the tampered `to` AND must honor TAMPER_BLOCK_LIMIT (or
                // the offline default) for its base blockLimit — the live-chain regression this
                // guards against: a base blockLimit outside the chain's valid window makes the
                // node reject at the blockLimit gate before it ever reaches `to` validation,
                // which would make illegal_to a false-green for the wrong reason.
                long expectedBaseBlockLimit = baseBlockLimit();
                String illegalToHex = tamper("illegal_to", suite);
                Transaction decoded1 = TransactionStructBuilderJniObj.decodeTransactionStruct(illegalToHex);
                String decodedTo = decoded1.getTransactionData().getTo();
                long decodedIllegalToBlockLimit = decoded1.getTransactionData().getBlockLimit();
                ok &= report("illegal_to", ILLEGAL_TO.equals(decodedTo)
                                && decodedIllegalToBlockLimit == expectedBaseBlockLimit,
                        "decoded to='" + decodedTo + "' expected='" + ILLEGAL_TO + "'"
                                + ", decoded blockLimit=" + decodedIllegalToBlockLimit
                                + " expected=" + expectedBaseBlockLimit
                                + " (TAMPER_BLOCK_LIMIT="
                                + System.getenv("TAMPER_BLOCK_LIMIT") + ")");

                // oob_field must ignore TAMPER_BLOCK_LIMIT and always force its own bad value —
                // that case's whole point IS a bad blockLimit.
                String oobHex = tamper("oob_field", suite);
                Transaction decoded2 = TransactionStructBuilderJniObj.decodeTransactionStruct(oobHex);
                long decodedBlockLimit = decoded2.getTransactionData().getBlockLimit();
                ok &= report("oob_field", decodedBlockLimit == BAD_BLOCK_LIMIT,
                        "decoded blockLimit=" + decodedBlockLimit + " expected=" + BAD_BLOCK_LIMIT
                                + " (must ignore TAMPER_BLOCK_LIMIT="
                                + System.getenv("TAMPER_BLOCK_LIMIT") + ")");

                SignedPair pair = buildBadSignatureCase(suite);
                Transaction goodTx = TransactionStructBuilderJniObj.decodeTransactionStruct(pair.goodHex);
                Transaction badTx = TransactionStructBuilderJniObj.decodeTransactionStruct(pair.badHex);
                boolean signatureDiffers = !Arrays.equals(goodTx.getSignature(), badTx.getSignature());
                boolean dataHashUnchanged = Arrays.equals(goodTx.getDataHash(), badTx.getDataHash());
                boolean sameData =
                        goodTx.getTransactionData().getTo().equals(badTx.getTransactionData().getTo())
                                && goodTx.getTransactionData().getBlockLimit()
                                        == badTx.getTransactionData().getBlockLimit();
                ok &= report("bad_signature", signatureDiffers && dataHashUnchanged && sameData,
                        "signatureDiffers=" + signatureDiffers
                                + " dataHashUnchanged=" + dataHashUnchanged
                                + " sameData=" + sameData);
            } catch (Exception e) {
                System.err.println("SELFCHECK ERROR: " + e);
                e.printStackTrace();
                return false;
            }
            return ok;
        }

        private static boolean report(String caseName, boolean pass, String detail) {
            System.err.println((pass ? "PASS" : "FAIL") + ": selfcheck[" + caseName + "]: " + detail);
            return pass;
        }
    }
}
