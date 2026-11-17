// Residual-stream activations at the last token of a set of prompts that share a prefix (qwen4exp models).
// For each prompt: the mean over the hc streams of "l_last-<il>" at the final token, for every layer.
// Usage: acts model.gguf prompts.txt out.f32
//   prompts.txt: blocks separated by a line "====": the first block is the shared prefix, the rest are endings.
//   out.f32: float32 [n_endings][n_layer][n_embd]
// The prefix is evaluated once and its state restored before each ending.  CPU only.
// Build: g++ -O2 -std=c++17 acts.cpp -I ~/llama.cpp/include -I ~/llama.cpp/ggml/include -L ~/llama.cpp/build-hotswap/bin \
//        -lllama -lggml -lggml-base -Wl,-rpath,$HOME/llama.cpp/build-hotswap/bin -o acts
#include "llama.h"
#include "ggml.h"
#include "ggml-backend.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <fstream>
#include <sstream>

struct ud_t { int n_layer = 0, n_embd = 0; std::vector<float> cur; };

static bool cb_eval(struct ggml_tensor * t, bool ask, void * user_data) {
    ud_t * ud = (ud_t *) user_data;
    if (strncmp(t->name, "l_last-", 7) != 0) return ask ? false : true;
    if (ask) return true;
    const int il = atoi(t->name + 7);
    if (il < 0 || il >= ud->n_layer) return true;
    const int64_t ne0 = t->ne[0], hc = t->ne[1], nt = t->ne[2];
    std::vector<float> buf(ne0 * hc);
    ggml_backend_tensor_get(t, buf.data(), (nt - 1) * hc * ne0 * sizeof(float), buf.size() * sizeof(float));
    float * dst = ud->cur.data() + (size_t) il * ud->n_embd;
    for (int64_t i = 0; i < ne0; i++) { float s = 0; for (int64_t c = 0; c < hc; c++) s += buf[c*ne0 + i]; dst[i] = s / hc; }
    return true;
}

static std::vector<llama_token> tok(const llama_vocab * v, const std::string & s, bool bos) {
    std::vector<llama_token> t(s.size() + 16);
    int n = llama_tokenize(v, s.c_str(), s.size(), t.data(), t.size(), bos, true);
    if (n < 0) { fprintf(stderr, "tokenize failed\n"); exit(4); }
    t.resize(n); return t;
}

static void decode(llama_context * ctx, const std::vector<llama_token> & t, int pos0) {
    llama_batch b = llama_batch_init(t.size(), 0, 1); b.n_tokens = t.size();
    for (size_t i = 0; i < t.size(); i++) { b.token[i] = t[i]; b.pos[i] = pos0 + i; b.n_seq_id[i] = 1; b.seq_id[i][0] = 0; b.logits[i] = 0; }
    b.logits[t.size() - 1] = 1;
    if (llama_decode(ctx, b) != 0) { fprintf(stderr, "decode failed\n"); exit(5); }
    llama_batch_free(b);
}

int main(int argc, char ** argv) {
    if (argc < 4) { fprintf(stderr, "usage: %s model prompts.txt out.f32\n", argv[0]); return 1; }
    llama_backend_init();
    auto mp = llama_model_default_params(); mp.n_gpu_layers = 0; static ggml_backend_dev_t nodev[1] = { nullptr }; mp.devices = nodev;
    llama_model * model = llama_model_load_from_file(argv[1], mp);
    if (!model) return 2;
    const llama_vocab * vocab = llama_model_get_vocab(model);
    ud_t ud; ud.n_layer = llama_model_n_layer(model); ud.n_embd = llama_model_n_embd(model); ud.cur.assign((size_t) ud.n_layer * ud.n_embd, 0.0f);
    auto cp = llama_context_default_params();
    cp.n_ctx = 4096; cp.n_batch = 2048; cp.n_ubatch = 2048; cp.n_threads = 16; cp.n_threads_batch = 16;
    cp.cb_eval = cb_eval; cp.cb_eval_user_data = &ud; cp.no_perf = true;
    llama_context * ctx = llama_init_from_model(model, cp);
    if (!ctx) return 3;

    std::ifstream f(argv[2]); std::stringstream ss; ss << f.rdbuf();
    std::vector<std::string> blocks; { std::string cur, line; std::istringstream is(ss.str()); bool first = true;
      while (std::getline(is, line)) { if (line == "====") { blocks.push_back(cur); cur.clear(); first = true; } else { if (!first) cur += "\n"; cur += line; first = false; } }
      blocks.push_back(cur); }
    if (blocks.size() < 2) { fprintf(stderr, "need a prefix and at least one ending\n"); return 6; }

    auto pre = tok(vocab, blocks[0], true);
    decode(ctx, pre, 0);
    std::vector<uint8_t> state(llama_state_seq_get_size(ctx, 0));
    llama_state_seq_get_data(ctx, state.data(), state.size(), 0);
    fprintf(stderr, "prefix %zu tokens, state %zu bytes\n", pre.size(), state.size());

    FILE * out = fopen(argv[3], "wb");
    for (size_t i = 1; i < blocks.size(); i++) {
        llama_memory_clear(llama_get_memory(ctx), true);
        if (llama_state_seq_set_data(ctx, state.data(), state.size(), 0) == 0) { fprintf(stderr, "state restore failed\n"); return 7; }
        auto t = tok(vocab, blocks[i], false);
        decode(ctx, t, (int) pre.size());
        fwrite(ud.cur.data(), sizeof(float), ud.cur.size(), out);
        fprintf(stderr, "ending %zu: %zu tokens\n", i, t.size());
    }
    fclose(out);
    llama_free(ctx); llama_model_free(model); llama_backend_free();
    return 0;
}
