import XCTest
import LlamaCore

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
        XCTAssertEqual(model.n_gpu_layers, -1)
        let ctx = llama_context_default_params()
        XCTAssertGreaterThan(ctx.n_ctx, 0)
    }
}
