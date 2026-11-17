// Per-layer size of the residual leaving each block of a hyper-connection model (qwen4exp, e.g. Qwen3.8-Flash-Next):
// the L2 norm of each of the hc streams of "l_last-<il>" at each token, skipping position 0 of each sequence.
// The median over tokens and streams is the dose unit of that layer (same definition as metrovoc/neuron-steering's
// rnorm).  Also prints the norm of the FFN output the steering vector is added to ("ffn_out-<il>").
// Usage: resid_norms model.gguf textfile      (CPU only; sequences in the text are separated by a line "====")
// Build: g++ -O2 -std=c++17 resid_norms.cpp -I ~/llama.cpp/include -I ~/llama.cpp/ggml/include \
//        -L ~/llama.cpp/build-hotswap/bin -lllama -lggml -lggml-base -Wl,-rpath,$HOME/llama.cpp/build-hotswap/bin -o resid_norms
#include "llama.h"
#include "ggml-backend.h"
#include <cstdio>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>
#include <map>
#include <fstream>
#include <sstream>
#include <algorithm>

struct ud_t { std::map<int, std::vector<double>> norms, ffn; };

static bool cb_eval(struct ggml_tensor * t, bool ask, void * user_data) {
    ud_t * ud = (ud_t *) user_data;
    const char * name = t->name;
    const bool is_res = strncmp(name, "l_last-", 7) == 0;
    const bool is_ffn = strncmp(name, "ffn_out-", 8) == 0;
    if (ask) return is_res || is_ffn;
    if (!is_res && !is_ffn) return true;
    const int il = atoi(strchr(name, '-') + 1);
    const int64_t ne0 = t->ne[0];
    const int64_t rows = ggml_nelements(t) / ne0;          // streams x tokens (or tokens)
    const int64_t per_tok = is_res ? t->ne[1] : 1;
    std::vector<float> buf(ne0 * rows);
    ggml_backend_tensor_get(t, buf.data(), 0, buf.size() * sizeof(float));
    for (int64_t r = per_tok; r < rows; r++) {             // skip position 0
        double s = 0; for (int64_t i = 0; i < ne0; i++) { double v = buf[r*ne0+i]; s += v*v; }
        (is_res ? ud->norms : ud->ffn)[il].push_back(std::sqrt(s));
    }
    return true;
}

int main(int argc, char ** argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s model text\n", argv[0]); return 1; }
    ud_t ud;
    llama_backend_init();
    auto mp = llama_model_default_params(); mp.n_gpu_layers = 0; static ggml_backend_dev_t nodev[1] = { nullptr }; mp.devices = nodev;
    llama_model * model = llama_model_load_from_file(argv[1], mp);
    if (!model) return 2;
    const llama_vocab * vocab = llama_model_get_vocab(model);
    auto cp = llama_context_default_params();
    cp.n_ctx = 1024; cp.n_batch = 1024; cp.n_ubatch = 1024; cp.n_threads = 16; cp.n_threads_batch = 16;
    cp.cb_eval = cb_eval; cp.cb_eval_user_data = &ud; cp.no_perf = true;
    llama_context * ctx = llama_init_from_model(model, cp);
    if (!ctx) return 3;

    std::ifstream f(argv[2]); std::stringstream ss; ss << f.rdbuf(); std::string all = ss.str();
    // split sequences on a line containing only "===="
    std::vector<std::string> seqs; { std::string cur, line; std::istringstream is(all);
      while (std::getline(is, line)) { if (line == "====") { if (!cur.empty()) seqs.push_back(cur); cur.clear(); } else cur += line + "\n"; }
      if (!cur.empty()) seqs.push_back(cur); }
    int total = 0;
    for (auto & s : seqs) {
        std::vector<llama_token> toks(s.size() + 16);
        int n = llama_tokenize(vocab, s.c_str(), s.size(), toks.data(), toks.size(), true, true);
        if (n < 0) { fprintf(stderr, "tokenize failed\n"); return 4; }
        toks.resize(n); total += n;
        llama_memory_clear(llama_get_memory(ctx), true);
        llama_batch batch = llama_batch_init(n, 0, 1); batch.n_tokens = n;
        for (int i = 0; i < n; i++) { batch.token[i] = toks[i]; batch.pos[i] = i; batch.n_seq_id[i] = 1; batch.seq_id[i][0] = 0; batch.logits[i] = 0; }
        batch.logits[n-1] = 1;
        if (llama_decode(ctx, batch) != 0) { fprintf(stderr, "decode failed\n"); return 5; }
        llama_batch_free(batch);
        fprintf(stderr, "seq of %d tokens done\n", n);
    }
    fprintf(stderr, "total tokens %d, sequences %zu\n", total, seqs.size());
    auto med = [](std::vector<double> v) { if (v.empty()) return 0.0; std::sort(v.begin(), v.end()); size_t n = v.size(); return n % 2 ? v[n/2] : 0.5*(v[n/2-1]+v[n/2]); };
    printf("{\n");
    bool first = true;
    for (auto & kv : ud.norms) {
        auto v = kv.second; std::sort(v.begin(), v.end()); size_t n = v.size();
        printf("%s  \"%d\": {\"unit\": %.4f, \"p10\": %.4f, \"p90\": %.4f, \"ffn_out\": %.4f, \"n\": %zu}", first ? "" : ",\n", kv.first, med(v), v[n/10], v[n*9/10], med(ud.ffn[kv.first]), n);
        first = false;
    }
    printf("\n}\n");
    llama_free(ctx); llama_model_free(model); llama_backend_free();
    return 0;
}
