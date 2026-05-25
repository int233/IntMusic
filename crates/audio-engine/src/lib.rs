use std::path::Path;

use anyhow::Result;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Codec {
    Mp3,
    Flac,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AudioFormat {
    pub codec: Codec,
    pub sample_rate: u32,
    pub channels: u16,
    pub bit_depth: Option<u16>,
    pub duration_ms: u64,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct PcmFormat {
    pub sample_rate: u32,
    pub channels: u16,
}

#[derive(Debug, Clone)]
pub struct AudioBuffer {
    pub format: PcmFormat,
    pub frames: usize,
    pub samples: Vec<f32>,
}

pub trait Decoder {
    fn open(path: &Path) -> Result<Self>
    where
        Self: Sized;

    fn format(&self) -> AudioFormat;

    fn read_pcm(&mut self, frames: usize) -> Result<AudioBuffer>;
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReplayGain {
    pub track_gain_db: Option<f32>,
    pub album_gain_db: Option<f32>,
    pub track_peak: Option<f32>,
    pub album_peak: Option<f32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignalPathStep {
    pub name: String,
    pub details: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SignalPath {
    pub steps: Vec<SignalPathStep>,
}

pub fn codec_from_extension(path: &Path) -> Option<Codec> {
    match path.extension()?.to_str()?.to_ascii_lowercase().as_str() {
        "mp3" => Some(Codec::Mp3),
        "flac" => Some(Codec::Flac),
        _ => None,
    }
}
