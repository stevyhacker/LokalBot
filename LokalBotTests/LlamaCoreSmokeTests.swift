import XCTest
import LlamaCore

/// Proves the LlamaCore module imports, the vendored libllama.dylib links, and
/// the @rpath resolves at runtime by executing real v0.4.1 C calls.
final class LlamaCoreSmokeTests: XCTestCase {
    func testPenaltiesSamplerUsesVocabularySizeAndPenalizesAcceptedTokens() throws {
        let sampler = try XCTUnwrap(llama_sampler_init_penalties(2, 64, 2, 0, 0))
        defer { llama_sampler_free(sampler) }
        llama_sampler_accept(sampler, 0)
        var candidates = [
            llama_token_data(id: 0, logit: 4, p: 0),
            llama_token_data(id: 1, logit: 4, p: 0),
        ]
        candidates.withUnsafeMutableBufferPointer { buffer in
            var data = llama_token_data_array(data: buffer.baseAddress, size: buffer.count,
                                             selected: -1, sorted: false)
            llama_sampler_apply(sampler, &data)
        }
        XCTAssertEqual(candidates[0].logit, 2)
        XCTAssertEqual(candidates[1].logit, 4)
    }

    func testBackendInitAndDefaultParamsLink() {
        llama_backend_init()
        let model = llama_model_default_params()
        // The n_gpu_layers field must be reachable through the imported struct.
        // v0.4.1 defaults it to -1 ("a negative value means all layers" per
        // llama.h) — i.e. full Metal offload, exactly what the runtime wants.
        XCTAssertEqual(model.n_gpu_layers, -1)
        let ctx = llama_context_default_params()
        XCTAssertGreaterThan(ctx.n_ctx, 0)
        // Intentionally NOT calling llama_backend_free(): this runs in the shared
        // test process, and freeing the global backend here would be a footgun for
        // any test class that loads a model (LlamaCotypingRuntime's once-let init).
        // The smoke test's purpose — LlamaCore imports, dylib links, default-params
        // structs resolve — needs no teardown.
    }
}
