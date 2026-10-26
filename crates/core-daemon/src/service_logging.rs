use std::{
    fs::{self, OpenOptions},
    io::{self, Write},
    path::{Path, PathBuf},
    sync::Mutex,
};
use tracing_subscriber::{fmt, EnvFilter};

static WRITE_LOCK: Mutex<()> = Mutex::new(());

pub fn initialize(filter: EnvFilter, path: PathBuf) {
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let _ = fmt()
        .with_ansi(false)
        .with_env_filter(filter)
        .with_writer(move || LogLine {
            path: path.clone(),
            bytes: Vec::new(),
        })
        .try_init();
}

struct LogLine {
    path: PathBuf,
    bytes: Vec<u8>,
}

impl Write for LogLine {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.bytes.extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl Drop for LogLine {
    fn drop(&mut self) {
        if !self.bytes.is_empty() {
            let _ = append(&self.path, &self.bytes, 10 * 1024 * 1024);
        }
    }
}

fn append(path: &Path, bytes: &[u8], max_bytes: u64) -> io::Result<()> {
    let _guard = WRITE_LOCK.lock().unwrap_or_else(|error| error.into_inner());
    if fs::metadata(path).map(|m| m.len()).unwrap_or(0) + bytes.len() as u64 > max_bytes {
        let previous = PathBuf::from(format!("{}.1", path.display()));
        let oldest = PathBuf::from(format!("{}.2", path.display()));
        if oldest.exists() {
            fs::remove_file(&oldest)?;
        }
        if previous.exists() {
            fs::rename(&previous, &oldest)?;
        }
        if path.exists() {
            fs::rename(path, &previous)?;
        }
    }
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?
        .write_all(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tracing_events_are_written_to_the_service_log() {
        let directory =
            std::env::temp_dir().join(format!("intmusic-tracing-log-{}", std::process::id()));
        fs::create_dir_all(&directory).unwrap();
        let path = directory.join("service.log");
        initialize(EnvFilter::new("info"), path.clone());
        tracing::info!("service tracing is captured");
        assert!(fs::read_to_string(path)
            .unwrap()
            .contains("service tracing is captured"));
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn retains_recent_logs_after_rotation() {
        let directory =
            std::env::temp_dir().join(format!("intmusic-service-log-{}", std::process::id()));
        fs::create_dir_all(&directory).unwrap();
        let path = directory.join("service.log");
        for number in 0..8 {
            append(&path, format!("event {number}\n").as_bytes(), 16).unwrap();
        }
        assert!(fs::read_to_string(&path).unwrap().contains("event 7"));
        assert!(directory.join("service.log.1").exists());
        assert!(directory.join("service.log.2").exists());
        assert!(!directory.join("service.log.3").exists());
        fs::remove_dir_all(directory).unwrap();
    }
}
