package fisco.tamperfuzz;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.math.BigInteger;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Random;

/**
 * EthMethodFuzzGenerator — the eth_* / net_* / web3_* METHOD-SURFACE analogue of Web3FuzzGenerator
 * (see that class's doc for the shared TSV/determinism contract this mirrors). Invoked as `java
 * -jar tamper-fuzz-all.jar ethmethodfuzz <count> <seed> <strategy>`, strategy in {struct, bytes,
 * both}. Prints <count> TSV lines to stdout: `<idx>\t<kind>\t<detail>\t<envelope>`, kind in
 * {struct, bytes}. UNLIKE FuzzGenerator/Web3FuzzGenerator, whose 4th column is a bare tx hex
 * fuzzing the payload of ONE fixed method, this generator's 4th column is a COMPLETE JSON-RPC
 * request body (`{"jsonrpc":"2.0","id":1,"method":"<method>","params":<mutated>}`) ready to POST
 * verbatim — because the METHOD ITSELF varies per idx, drawn from CATALOG (the ~45 registered
 * eth_* / net_* / web3_* methods bcos-rpc's EndpointsMapping.cpp exposes with OP's `engine_*` methods
 * excluded — that engine is off on the live gate chain, see the task brief). This fuzzes the
 * JSON-RPC parser + per-method param decoders, a different bug class from
 * Web3FuzzGenerator/FuzzGenerator's RLP/tars payload-decode targets.
 *
 * DETERMINISM CONTRACT: identical to Web3FuzzGenerator's — exactly one java.util.Random(seed)
 * drives every choice (which method, which mutation kind, every mutated value, every byte-op
 * offset/length), in a FIXED per-idx call order, so the same (count, seed, strategy) always
 * replays the exact same sequence of Random draws and therefore byte-identical output, and idx-k
 * is identical regardless of the requested count (no draw anywhere depends on `count`).
 * `ethmethodfuzz --selfcheck` asserts both determinism and count-independence directly.
 */
final class EthMethodFuzzGenerator {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    // Baseline seed values (task brief "Baseline valid values" section) — a well-known throwaway
    // dev address (Hardhat's default account #0), never trusted for anything live.
    private static final String ADDR = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266";
    private static final String POSITION_OR_INDEX = "0x0";
    private static final String HASH = "0x" + buildZeroHex(32); // 0x + 64 hex chars
    private static final String DATA_HEX = "0x1234";
    private static final String FILTER_ID = "0x1";
    private static final String[] BLOCK_TAGS = {"latest", "earliest", "pending", "0x0", "0x21"};

    private static final BigInteger MAX_UINT256 =
            new BigInteger(
                    "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF", 16);

    // Deep-nesting / giant-array boundary sizes: capped so the generator itself stays fast (task
    // brief: "ethmethodfuzz 200 <seed> both" must return in a couple seconds) while still being
    // deep/large enough to exercise the node's JSON parser limits. 500 stays safely under
    // Jackson's own default StreamReadConstraints max-nesting-depth (1000 as of 2.15+), so
    // selfcheck's readTree round-trip on a struct-kind deeply-nested line does not itself throw.
    private static final int NESTED_DEPTH = 500;
    private static final int GIANT_ARRAY_SIZE = 50_000;
    private static final int OVERSIZED_HEX_BYTES = 50_000; // -> ~100KB of hex text

    /** Param shape groups from the confirmed method catalog (task brief). Each shape maps to a
     * fixed baseline-params recipe in buildBaselineParams. */
    private enum Shape {
        NULLARY,
        ADDR_BLOCK,
        ADDR_POS_BLOCK,
        ADDR_KEYS_BLOCK,
        BLOCKNUM_BOOL,
        BLOCKNUM,
        BLOCKNUM_INDEX,
        BLOCKHASH_BOOL,
        BLOCKHASH,
        BLOCKHASH_INDEX,
        TXHASH,
        TXOBJ_BLOCK,
        TXOBJ_ONLY,
        DATAHEX,
        ADDR_DATAHEX,
        FILTEROBJ,
        FILTERID
    }

    private static final class MethodSpec {
        final String name;
        final Shape shape;

        MethodSpec(String name, Shape shape) {
            this.name = name;
            this.shape = shape;
        }
    }

    // The confirmed method catalog (task brief; engine_* excluded — OP engine is off on the live
    // gate chain, every engine_* call there returns -32601). Order does not matter for the
    // determinism contract (CATALOG.length is fixed, only the RNG-drawn INDEX matters), but keep
    // it stable anyway — reordering changes which method every existing (seed,idx) draws.
    private static final MethodSpec[] CATALOG = {
        new MethodSpec("eth_protocolVersion", Shape.NULLARY),
        new MethodSpec("eth_syncing", Shape.NULLARY),
        new MethodSpec("eth_coinbase", Shape.NULLARY),
        new MethodSpec("eth_chainId", Shape.NULLARY),
        new MethodSpec("eth_mining", Shape.NULLARY),
        new MethodSpec("eth_hashrate", Shape.NULLARY),
        new MethodSpec("eth_gasPrice", Shape.NULLARY),
        new MethodSpec("eth_accounts", Shape.NULLARY),
        new MethodSpec("eth_blockNumber", Shape.NULLARY),
        new MethodSpec("eth_maxPriorityFeePerGas", Shape.NULLARY),
        new MethodSpec("eth_newBlockFilter", Shape.NULLARY),
        new MethodSpec("eth_newPendingTransactionFilter", Shape.NULLARY),
        new MethodSpec("net_version", Shape.NULLARY),
        new MethodSpec("net_peerCount", Shape.NULLARY),
        new MethodSpec("net_listening", Shape.NULLARY),
        new MethodSpec("web3_clientVersion", Shape.NULLARY),
        new MethodSpec("eth_getBalance", Shape.ADDR_BLOCK),
        new MethodSpec("eth_getTransactionCount", Shape.ADDR_BLOCK),
        new MethodSpec("eth_getCode", Shape.ADDR_BLOCK),
        new MethodSpec("eth_getStorageAt", Shape.ADDR_POS_BLOCK),
        new MethodSpec("eth_getProof", Shape.ADDR_KEYS_BLOCK),
        new MethodSpec("eth_getBlockByNumber", Shape.BLOCKNUM_BOOL),
        new MethodSpec("eth_getBlockTransactionCountByNumber", Shape.BLOCKNUM),
        new MethodSpec("eth_getUncleCountByBlockNumber", Shape.BLOCKNUM),
        new MethodSpec("eth_getTransactionByBlockNumberAndIndex", Shape.BLOCKNUM_INDEX),
        new MethodSpec("eth_getUncleByBlockNumberAndIndex", Shape.BLOCKNUM_INDEX),
        new MethodSpec("eth_getBlockByHash", Shape.BLOCKHASH_BOOL),
        new MethodSpec("eth_getBlockTransactionCountByHash", Shape.BLOCKHASH),
        new MethodSpec("eth_getUncleCountByBlockHash", Shape.BLOCKHASH),
        new MethodSpec("eth_getTransactionByBlockHashAndIndex", Shape.BLOCKHASH_INDEX),
        new MethodSpec("eth_getUncleByBlockHashAndIndex", Shape.BLOCKHASH_INDEX),
        new MethodSpec("eth_getTransactionByHash", Shape.TXHASH),
        new MethodSpec("eth_getTransactionReceipt", Shape.TXHASH),
        new MethodSpec("eth_call", Shape.TXOBJ_BLOCK),
        new MethodSpec("eth_estimateGas", Shape.TXOBJ_ONLY),
        new MethodSpec("eth_sendTransaction", Shape.TXOBJ_ONLY),
        new MethodSpec("eth_signTransaction", Shape.TXOBJ_ONLY),
        new MethodSpec("web3_sha3", Shape.DATAHEX),
        new MethodSpec("eth_sendRawTransaction", Shape.DATAHEX),
        new MethodSpec("eth_sign", Shape.ADDR_DATAHEX),
        new MethodSpec("eth_newFilter", Shape.FILTEROBJ),
        new MethodSpec("eth_getLogs", Shape.FILTEROBJ),
        new MethodSpec("eth_uninstallFilter", Shape.FILTERID),
        new MethodSpec("eth_getFilterChanges", Shape.FILTERID),
        new MethodSpec("eth_getFilterLogs", Shape.FILTERID),
    };

    private EthMethodFuzzGenerator() {}

    /** validate <strategy>: struct | bytes | both. Throws IllegalArgumentException otherwise,
     * turned into the documented non-zero-exit-plus-stderr contract by the caller (main). */
    static void validateStrategy(String strategy) {
        if (!"struct".equals(strategy) && !"bytes".equals(strategy) && !"both".equals(strategy)) {
            throw new IllegalArgumentException(
                    "unknown ethmethodfuzz strategy '"
                            + strategy
                            + "'; expected one of: struct, bytes, both");
        }
    }

    /** generate <count> mutant TSV lines for (seed, strategy). Pure function of its three
     * arguments — see class doc DETERMINISM CONTRACT. */
    static List<String> generate(int count, long seed, String strategy) {
        validateStrategy(strategy);
        if (count < 0) {
            throw new IllegalArgumentException("count must be >= 0, got " + count);
        }
        Random rng = new Random(seed);
        List<String> lines = new ArrayList<>(count);
        for (int idx = 0; idx < count; idx++) {
            String kind = strategy;
            if ("both".equals(strategy)) {
                kind = rng.nextBoolean() ? "struct" : "bytes";
            }
            Mutant m = "struct".equals(kind) ? generateStructMutant(rng) : generateBytesMutant(rng);
            lines.add(idx + "\t" + m.kind + "\t" + m.detail + "\t" + m.envelope);
        }
        return lines;
    }

    /** ethmethodfuzz --selfcheck: assert (1) determinism, (2) count-independence (idx-5 of a
     * run of 10 == idx-5 of a run of 30), (3) struct-kind lines are valid JSON carrying a
     * `method` from CATALOG, (4) bytes-kind lines are allowed to fail parsing (that is the point
     * of raw text corruption). All output to stderr, mirroring the other generators' selfchecks. */
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

            List<String> run10 = generate(10, 777L, "both");
            List<String> run30 = generate(30, 777L, "both");
            String line5of10 = run10.get(5);
            String line5of30 = run30.get(5);
            boolean countIndependent = line5of10.equals(line5of30);
            ok &=
                    report(
                            "count_independence",
                            countIndependent,
                            "idx-5 of generate(10,777,both) "
                                    + (countIndependent ? "==" : "!=")
                                    + " idx-5 of generate(30,777,both)");

            int structTotal = 0, structValid = 0, bytesTotal = 0, badShape = 0;
            for (String line : run1) {
                String[] cols = line.split("\t", -1);
                if (cols.length != 4) {
                    badShape++;
                    continue;
                }
                String kind = cols[1];
                String envelope = cols[3];
                if ("struct".equals(kind)) {
                    structTotal++;
                    try {
                        JsonNode node = MAPPER.readTree(envelope);
                        JsonNode methodNode = node.get("method");
                        if (methodNode != null && isKnownMethod(methodNode.asText())) {
                            structValid++;
                        }
                    } catch (Exception e) {
                        // not counted as valid; reported via structValid < structTotal below
                    }
                } else if ("bytes".equals(kind)) {
                    bytesTotal++;
                } else {
                    badShape++;
                }
            }
            ok &=
                    report(
                            "line_shape", badShape == 0, badShape + " lines with a bad TSV shape (expect 0)");
            ok &=
                    report(
                            "struct_valid_json",
                            structTotal > 0 && structValid == structTotal,
                            structValid
                                    + "/"
                                    + structTotal
                                    + " struct-kind lines parsed as valid JSON with a known `method`"
                                    + " (expect all)");
            report(
                    "bytes_present",
                    true,
                    bytesTotal + " bytes-kind lines observed (unparseable is fine, not scored)");
        } catch (Exception e) {
            System.err.println("ETHMETHODFUZZ SELFCHECK ERROR: " + e);
            e.printStackTrace();
            return false;
        }
        return ok;
    }

    private static boolean isKnownMethod(String name) {
        for (MethodSpec spec : CATALOG) {
            if (spec.name.equals(name)) {
                return true;
            }
        }
        return false;
    }

    private static boolean report(String name, boolean pass, String detail) {
        System.err.println(
                (pass ? "PASS" : "FAIL") + ": ethmethodfuzz-selfcheck[" + name + "]: " + detail);
        return pass;
    }

    // -------------------------------------------------------------------------------------------
    // struct strategy — valid JSON, bad semantics
    // -------------------------------------------------------------------------------------------

    /** Pick a method, build its valid baseline params, apply exactly ONE mutation. Nullary
     * methods only get the arity attack (giving non-empty params to a method that expects none —
     * there is no field to wrong-type or boundary-mutate). Every other method picks uniformly
     * among {wrongType, arity, boundary} plus, for methods carrying a txObject/filterObject, a
     * 4th option that malforms one nested field inside that object. */
    private static Mutant generateStructMutant(Random r) {
        MethodSpec spec = CATALOG[r.nextInt(CATALOG.length)];
        List<Object> params = buildBaselineParams(spec, r);
        String detail;
        if (spec.shape == Shape.NULLARY) {
            detail = mutateArity(spec.name, params, r, true);
        } else {
            boolean complex = hasComplexField(spec.shape);
            int options = complex ? 4 : 3;
            int pick = r.nextInt(options);
            switch (pick) {
                case 0:
                    detail = mutateWrongType(spec.name, params, r);
                    break;
                case 1:
                    detail = mutateArity(spec.name, params, r, false);
                    break;
                case 2:
                    detail = mutateBoundary(spec.name, params, r);
                    break;
                default:
                    detail = mutateComplexField(spec, params, r);
                    break;
            }
        }
        return new Mutant("struct", detail, buildEnvelope(spec.name, params));
    }

    private static boolean hasComplexField(Shape shape) {
        return shape == Shape.TXOBJ_BLOCK || shape == Shape.TXOBJ_ONLY || shape == Shape.FILTEROBJ;
    }

    /** Build the valid baseline `params` array for one method shape (task brief "Baseline valid
     * values"). Always returns a fresh, independently-mutable List/Map tree — callers mutate it
     * in place, so no baseline value may be a shared static instance. */
    private static List<Object> buildBaselineParams(MethodSpec spec, Random r) {
        List<Object> params = new ArrayList<>();
        switch (spec.shape) {
            case NULLARY:
                break;
            case ADDR_BLOCK:
                params.add(ADDR);
                params.add(randomBlockTag(r));
                break;
            case ADDR_POS_BLOCK:
                params.add(ADDR);
                params.add(POSITION_OR_INDEX);
                params.add(randomBlockTag(r));
                break;
            case ADDR_KEYS_BLOCK:
                {
                    List<Object> keys = new ArrayList<>();
                    keys.add(POSITION_OR_INDEX);
                    params.add(ADDR);
                    params.add(keys);
                    params.add(randomBlockTag(r));
                    break;
                }
            case BLOCKNUM_BOOL:
                params.add(randomBlockTag(r));
                params.add(Boolean.TRUE);
                break;
            case BLOCKNUM:
                params.add(randomBlockTag(r));
                break;
            case BLOCKNUM_INDEX:
                params.add(randomBlockTag(r));
                params.add(POSITION_OR_INDEX);
                break;
            case BLOCKHASH_BOOL:
                params.add(HASH);
                params.add(Boolean.TRUE);
                break;
            case BLOCKHASH:
                params.add(HASH);
                break;
            case BLOCKHASH_INDEX:
                params.add(HASH);
                params.add(POSITION_OR_INDEX);
                break;
            case TXHASH:
                params.add(HASH);
                break;
            case TXOBJ_BLOCK:
                params.add(buildTxObject());
                params.add(randomBlockTag(r));
                break;
            case TXOBJ_ONLY:
                params.add(buildTxObject());
                break;
            case DATAHEX:
                params.add(DATA_HEX);
                break;
            case ADDR_DATAHEX:
                params.add(ADDR);
                params.add(DATA_HEX);
                break;
            case FILTEROBJ:
                params.add(buildFilterObject());
                break;
            case FILTERID:
                params.add(FILTER_ID);
                break;
        }
        return params;
    }

    private static Map<String, Object> buildTxObject() {
        Map<String, Object> tx = new LinkedHashMap<>();
        tx.put("from", ADDR);
        tx.put("to", ADDR);
        tx.put("gas", "0x5208");
        tx.put("gasPrice", "0x0");
        tx.put("value", "0x0");
        tx.put("data", "0x");
        return tx;
    }

    private static Map<String, Object> buildFilterObject() {
        Map<String, Object> filter = new LinkedHashMap<>();
        filter.put("fromBlock", "earliest");
        filter.put("toBlock", "latest");
        filter.put("address", ADDR);
        filter.put("topics", new ArrayList<>());
        return filter;
    }

    private static String randomBlockTag(Random r) {
        return BLOCK_TAGS[r.nextInt(BLOCK_TAGS.length)];
    }

    /** (a) wrong type: replace one params slot with a value whose JSON type differs from the
     * original (string<->number<->bool<->null<->object<->array). */
    private static String mutateWrongType(String name, List<Object> params, Random r) {
        int idx = r.nextInt(params.size());
        Object original = params.get(idx);
        Object replacement = wrongTypeValue(original, r);
        params.set(idx, replacement);
        return "struct:" + name + ":arg" + idx + "=wrongtype:" + typeName(replacement);
    }

    private static Object wrongTypeValue(Object original, Random r) {
        List<Object> candidates = new ArrayList<>();
        candidates.add(BigInteger.valueOf(9_999_999L));
        candidates.add(Boolean.TRUE);
        candidates.add(null);
        candidates.add(new LinkedHashMap<String, Object>());
        candidates.add(new ArrayList<>());
        candidates.add("unexpected_string_value");
        List<Object> filtered = new ArrayList<>();
        for (Object c : candidates) {
            if (!sameJsonType(c, original)) {
                filtered.add(c);
            }
        }
        return filtered.get(r.nextInt(filtered.size()));
    }

    private static boolean sameJsonType(Object a, Object b) {
        return typeName(a).equals(typeName(b));
    }

    private static String typeName(Object v) {
        if (v == null) {
            return "null";
        }
        if (v instanceof String) {
            return "string";
        }
        if (v instanceof Boolean) {
            return "bool";
        }
        if (v instanceof Number) {
            return "number";
        }
        if (v instanceof Map) {
            return "object";
        }
        if (v instanceof List) {
            return "array";
        }
        return v.getClass().getSimpleName();
    }

    /** (b) wrong arity: drop a required slot, or append 1-3 extra junk slots. `forceAppend`
     * (nullary methods) always appends — there is no slot to drop from an empty params array. */
    private static String mutateArity(String name, List<Object> params, Random r, boolean forceAppend) {
        boolean drop = !forceAppend && !params.isEmpty() && r.nextBoolean();
        if (drop) {
            int idx = r.nextInt(params.size());
            params.remove(idx);
            return "struct:" + name + ":arity:drop_arg" + idx;
        }
        int n = 1 + r.nextInt(3);
        for (int i = 0; i < n; i++) {
            params.add(randomJunkValue(r));
        }
        return "struct:" + name + ":arity:extra=" + n;
    }

    private static Object randomJunkValue(Random r) {
        switch (r.nextInt(6)) {
            case 0:
                return "junk";
            case 1:
                return BigInteger.valueOf(r.nextInt(1_000_000));
            case 2:
                return Boolean.FALSE;
            case 3:
                return null;
            case 4:
                return new LinkedHashMap<String, Object>();
            default:
                return new ArrayList<>();
        }
    }

    /** (c) boundary: empty string, oversized hex (~100KB), huge integer (> 2^256), negative,
     * deeply-nested array (capped depth), or a giant array (capped size). */
    private static String mutateBoundary(String name, List<Object> params, Random r) {
        int idx = r.nextInt(params.size());
        StringBuilder tag = new StringBuilder();
        Object value = boundaryValue(r, tag);
        params.set(idx, value);
        return "struct:" + name + ":arg" + idx + "=boundary:" + tag;
    }

    private static Object boundaryValue(Random r, StringBuilder tagOut) {
        switch (r.nextInt(6)) {
            case 0:
                tagOut.append("empty_string");
                return "";
            case 1:
                tagOut.append("oversized_hex_~100kb");
                return oversizedHex(OVERSIZED_HEX_BYTES);
            case 2:
                tagOut.append("huge_integer_gt_2^256");
                return MAX_UINT256.add(BigInteger.ONE);
            case 3:
                tagOut.append("negative");
                return BigInteger.valueOf(-1);
            case 4:
                tagOut.append("deeply_nested_depth" + NESTED_DEPTH);
                return deeplyNestedArray(NESTED_DEPTH);
            default:
                tagOut.append("giant_array_" + GIANT_ARRAY_SIZE);
                return giantArray(GIANT_ARRAY_SIZE);
        }
    }

    // String.repeat is Java 11+; this class compiles against --release 8 (see build.gradle), so
    // build the fixed 64-hex-char zero string the Java-8-compatible way instead.
    private static String buildZeroHex(int lenBytes) {
        StringBuilder sb = new StringBuilder(lenBytes * 2);
        for (int i = 0; i < lenBytes * 2; i++) {
            sb.append('0');
        }
        return sb.toString();
    }

    private static String oversizedHex(int lenBytes) {
        StringBuilder sb = new StringBuilder(2 + lenBytes * 2);
        sb.append("0x");
        for (int i = 0; i < lenBytes * 2; i++) {
            sb.append('a');
        }
        return sb.toString();
    }

    /** Iterative build (no recursion on the way UP — just a loop wrapping `inner` in a new
     * one-element list each pass) so constructing
     * this never itself risks a StackOverflowError; NESTED_DEPTH caps how deep the later JSON
     * serialize/parse recursion (Jackson's own) goes. */
    private static Object deeplyNestedArray(int depth) {
        Object inner = new ArrayList<>();
        for (int i = 0; i < depth; i++) {
            List<Object> level = new ArrayList<>();
            level.add(inner);
            inner = level;
        }
        return inner;
    }

    private static Object giantArray(int n) {
        List<Object> arr = new ArrayList<>(n);
        for (int i = 0; i < n; i++) {
            arr.add(i);
        }
        return arr;
    }

    /** (d) malformed-but-typed field inside txObject/filterObject: a JSON-valid value of the
     * "expected" type but semantically wrong (short address, non-array topics, block-tag-shaped
     * object). Only called when hasComplexField(spec.shape) — params.get(0) is always the
     * txObject/filterObject Map for every shape this is reachable from. */
    @SuppressWarnings("unchecked")
    private static String mutateComplexField(MethodSpec spec, List<Object> params, Random r) {
        if (spec.shape == Shape.TXOBJ_BLOCK || spec.shape == Shape.TXOBJ_ONLY) {
            Map<String, Object> txObject = (Map<String, Object>) params.get(0);
            switch (r.nextInt(3)) {
                case 0:
                    txObject.put("to", "0x1234"); // 2 bytes, not the required 20-byte address
                    return "struct:" + spec.name + ":txObject.to=short2bytes";
                case 1:
                    txObject.put("gas", new LinkedHashMap<String, Object>());
                    return "struct:" + spec.name + ":txObject.gas=object";
                default:
                    txObject.put("value", "not_a_hex_number");
                    return "struct:" + spec.name + ":txObject.value=malformed_string";
            }
        } else {
            Map<String, Object> filterObject = (Map<String, Object>) params.get(0);
            if (r.nextBoolean()) {
                filterObject.put("topics", "not_an_array");
                return "struct:" + spec.name + ":filterObject.topics=string";
            }
            Map<String, Object> badFromBlock = new LinkedHashMap<>();
            badFromBlock.put("not", "a_block_tag");
            filterObject.put("fromBlock", badFromBlock);
            return "struct:" + spec.name + ":filterObject.fromBlock=object";
        }
    }

    private static String buildEnvelope(String method, List<Object> params) {
        ObjectNode root = MAPPER.createObjectNode();
        root.put("jsonrpc", "2.0");
        root.put("id", 1);
        root.put("method", method);
        root.set("params", MAPPER.valueToTree(params));
        try {
            return MAPPER.writeValueAsString(root);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("failed to serialize envelope for " + method, e);
        }
    }

    // -------------------------------------------------------------------------------------------
    // bytes strategy — mostly invalid JSON: raw char-level corruption of a valid envelope's text
    // -------------------------------------------------------------------------------------------

    /** Build one valid envelope (random method + baseline params, no struct mutation) and apply
     * exactly one random char-level op to its JSON text. This fuzzes the JSON-RPC parser/framing
     * rather than the field-level decoders struct mutation targets, so the result is allowed to
     * be unparseable JSON — that is the point. */
    private static Mutant generateBytesMutant(Random r) {
        MethodSpec spec = CATALOG[r.nextInt(CATALOG.length)];
        List<Object> params = buildBaselineParams(spec, r);
        String envelope = buildEnvelope(spec.name, params);
        char[] raw = envelope.toCharArray();

        CharMutation m;
        switch (r.nextInt(5)) {
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
        return new Mutant("bytes", "bytes:" + spec.name + ":" + m.detail, new String(m.chars));
    }

    // Characters this driver's whole escaping design (Part B) exists to survive: quotes,
    // backslash, $, backtick, single-quote — the exact set the task brief calls out as
    // arbitrary/dangerous-to-the-shell content the bytes strategy must be free to emit.
    // DELIBERATELY EXCLUDES '\n'/'\r': this generator's own output contract is one mutant per
    // TSV line (idx\tkind\tdetail\tenvelope) — an embedded raw newline inside the envelope column
    // would split one mutant across two physical lines and desync every downstream `while
    // IFS=$'\t' read -r idx kind detail hex` consumer in fuzz_bcos.sh, which has no framing
    // beyond "one line = one mutant". Everything else in the pool (quotes/backslash/$/backtick/
    // punctuation) stays on a single line, so this exclusion is the only one needed.
    private static final char[] NASTY_CHARS = {
        '"', '\\', '$', '`', '\'', ';', '&', '|', '<', '>'
    };

    private static char randomChar(Random r) {
        // Half the time a "nasty" shell/JSON-special char, half the time a random printable ASCII
        // byte — a mix of targeted and generic corruption, same spirit as Web3FuzzGenerator's
        // opFlip drawing a random nonzero XOR mask. Printable ASCII 32..126 already excludes
        // newline (10) and CR (13), so this branch carries no framing risk either.
        if (r.nextBoolean()) {
            return NASTY_CHARS[r.nextInt(NASTY_CHARS.length)];
        }
        return (char) (32 + r.nextInt(95)); // printable ASCII 32..126
    }

    private static CharMutation opFlip(char[] raw, Random r) {
        if (raw.length == 0) {
            return new CharMutation(raw.clone(), "flip:noop_empty");
        }
        int n = 1 + r.nextInt(Math.min(5, raw.length));
        char[] mutated = raw.clone();
        StringBuilder offsets = new StringBuilder();
        for (int i = 0; i < n; i++) {
            int off = r.nextInt(mutated.length);
            mutated[off] = randomChar(r);
            if (i > 0) {
                offsets.append(';');
            }
            offsets.append(off);
        }
        return new CharMutation(mutated, "flip:n=" + n + ",offsets=" + offsets);
    }

    private static CharMutation opInsert(char[] raw, Random r) {
        int pos = raw.length == 0 ? 0 : r.nextInt(raw.length + 1);
        int len = 1 + r.nextInt(20);
        char[] ins = new char[len];
        for (int i = 0; i < len; i++) {
            ins[i] = randomChar(r);
        }
        return new CharMutation(insertAt(raw, pos, ins), "insert:offset=" + pos + ",len=" + len);
    }

    private static CharMutation opDelete(char[] raw, Random r) {
        if (raw.length == 0) {
            return new CharMutation(raw.clone(), "delete:noop_empty");
        }
        int start = r.nextInt(raw.length);
        int len = 1 + r.nextInt(raw.length - start);
        return new CharMutation(deleteRange(raw, start, len), "delete:offset=" + start + ",len=" + len);
    }

    private static CharMutation opTruncate(char[] raw, Random r) {
        int cut = raw.length == 0 ? 0 : r.nextInt(raw.length);
        char[] out = new char[cut];
        System.arraycopy(raw, 0, out, 0, cut);
        return new CharMutation(out, "truncate:len=" + cut);
    }

    private static CharMutation opDuplicate(char[] raw, Random r) {
        if (raw.length == 0) {
            return new CharMutation(raw.clone(), "duplicate:noop_empty");
        }
        int start = r.nextInt(raw.length);
        int len = 1 + r.nextInt(raw.length - start);
        char[] range = new char[len];
        System.arraycopy(raw, start, range, 0, len);
        return new CharMutation(
                insertAt(raw, start + len, range), "duplicate:offset=" + start + ",len=" + len);
    }

    private static char[] insertAt(char[] src, int pos, char[] insert) {
        char[] out = new char[src.length + insert.length];
        System.arraycopy(src, 0, out, 0, pos);
        System.arraycopy(insert, 0, out, pos, insert.length);
        System.arraycopy(src, pos, out, pos + insert.length, src.length - pos);
        return out;
    }

    private static char[] deleteRange(char[] src, int start, int len) {
        char[] out = new char[src.length - len];
        System.arraycopy(src, 0, out, 0, start);
        System.arraycopy(src, start + len, out, start, src.length - start - len);
        return out;
    }

    // -------------------------------------------------------------------------------------------
    // shared result types
    // -------------------------------------------------------------------------------------------

    private static final class Mutant {
        final String kind;
        final String detail;
        final String envelope;

        Mutant(String kind, String detail, String envelope) {
            this.kind = kind;
            this.detail = detail;
            this.envelope = envelope;
        }
    }

    private static final class CharMutation {
        final char[] chars;
        final String detail;

        CharMutation(char[] chars, String detail) {
            this.chars = chars;
            this.detail = detail;
        }
    }
}
