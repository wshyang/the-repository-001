# Current toolchains and sandbox-sized models

Generated from official release metadata. See SOURCES.md and SHA256SUMS.

- Go: go1.27.3 for linux/amd64
- Rust: 1.99.1 for x86_64-unknown-linux-gnu (rustc, rust-std, cargo, and available rustfmt/clippy)
- Coreference: biu-nlp/f-coref at revision e91dfff12879495d882ba9460d0c5d5dd44ade59 (license: mit)
- Optional tokenizer package: spaCy en_core_web_sm 3.8.0

The f-coref config sets _attn_implementation=eager for transformers==4.44.2.
The spaCy package is optional; the current pre-tokenized f-coref path does not need it.
