use pressay_asr::{
    analysis::{serve, Analysis},
    write_error,
};
use std::{
    io::{self, Write},
    path::Path,
};

unsafe extern "C" {
    fn pressay_protocol_start() -> i32;
    fn pressay_protocol_write(fd: i32, bytes: *const u8, size: u32) -> i32;
    fn pressay_protocol_close(fd: i32);
    fn pressay_worker_exit(code: i32) -> !;
}

struct ProtocolWriter(i32);

impl Write for ProtocolWriter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let size = bytes.len().min(i32::MAX as usize) as u32;
        let count = unsafe { pressay_protocol_write(self.0, bytes.as_ptr(), size) };
        if count < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(count as usize)
        }
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl Drop for ProtocolWriter {
    fn drop(&mut self) {
        unsafe { pressay_protocol_close(self.0) };
    }
}

fn run(output: &mut ProtocolWriter) -> Result<(), String> {
    let args: Vec<_> = std::env::args_os().collect();
    if args.len() != 4 {
        return Err(
            "Usage: pressay-analysis-worker <vad|diarize> <model-path> <runtime-directory>".into(),
        );
    }
    let model_id = args[1].to_str().ok_or("Invalid speech model identifier")?;
    let vad = match model_id {
        "vad" => true,
        "diarize" => false,
        _ => return Err("Unknown analysis mode".into()),
    };
    let mut engine = Analysis::load(vad, Path::new(&args[2]), Path::new(&args[3]))?;
    serve(&mut engine, &mut io::stdin().lock(), output).map_err(|error| error.to_string())
}

fn main() {
    let descriptor = unsafe { pressay_protocol_start() };
    if descriptor < 0 {
        eprintln!(
            "Could not open speech worker protocol pipe: {}",
            io::Error::last_os_error()
        );
        unsafe { pressay_worker_exit(1) };
    }
    let mut output = ProtocolWriter(descriptor);
    let code = match run(&mut output) {
        Ok(()) => 0,
        Err(error) => {
            let _ = write_error(&mut output, &error);
            1
        }
    };
    drop(output);
    unsafe { pressay_worker_exit(code) };
}
