use std::env;
use std::path::PathBuf;

fn main() {
    let crate_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
    let config = cbindgen::Config::from_file("cbindgen.toml")
        .unwrap_or_default();

    match cbindgen::Builder::new()
        .with_crate(crate_dir.clone())
        .with_config(config)
        .generate()
    {
        Ok(bindings) => {
            let out_path = PathBuf::from(&crate_dir).join("include").join("orbit.h");
            bindings.write_to_file(&out_path);
        }
        Err(e) => {
            eprintln!("cbindgen warning: {}", e);
        }
    }
}
