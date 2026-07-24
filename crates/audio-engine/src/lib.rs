use std::{fs::File, path::Path};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use symphonia::{
    core::{
        audio::SampleBuffer,
        codecs::DecoderOptions,
        errors::Error as SymphoniaError,
        formats::FormatOptions,
        io::{MediaSourceStream, MediaSourceStreamOptions},
        meta::MetadataOptions,
        probe::Hint,
    },
    default::{get_codecs, get_probe},
};

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

pub fn extract_waveform(path: &Path, requested_bins: usize) -> Result<Vec<f32>> {
    let bins = requested_bins.clamp(64, 4096);
    let file = File::open(path)
        .with_context(|| format!("failed to open audio file {}", path.display()))?;
    let stream = MediaSourceStream::new(Box::new(file), MediaSourceStreamOptions::default());
    let mut hint = Hint::new();
    if let Some(extension) = path.extension().and_then(|value| value.to_str()) {
        hint.with_extension(extension);
    }
    let probed = get_probe()
        .format(
            &hint,
            stream,
            &FormatOptions::default(),
            &MetadataOptions::default(),
        )
        .with_context(|| format!("failed to probe audio file {}", path.display()))?;
    let mut format = probed.format;
    let track = format
        .default_track()
        .context("audio file has no default track")?;
    let track_id = track.id;
    let mut decoder = get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .context("failed to create audio decoder")?;

    const FRAMES_PER_BLOCK: usize = 1024;
    let mut blocks = Vec::<f32>::new();
    let mut block_peak = 0.0_f32;
    let mut block_frames = 0_usize;

    loop {
        let packet = match format.next_packet() {
            Ok(packet) => packet,
            Err(SymphoniaError::IoError(error))
                if error.kind() == std::io::ErrorKind::UnexpectedEof =>
            {
                break;
            }
            Err(SymphoniaError::ResetRequired) => {
                decoder.reset();
                continue;
            }
            Err(error) => return Err(error).context("failed to read audio packet"),
        };
        if packet.track_id() != track_id {
            continue;
        }
        let decoded = match decoder.decode(&packet) {
            Ok(decoded) => decoded,
            Err(SymphoniaError::DecodeError(_)) => continue,
            Err(SymphoniaError::ResetRequired) => {
                decoder.reset();
                continue;
            }
            Err(error) => return Err(error).context("failed to decode audio packet"),
        };
        let channels = decoded.spec().channels.count().max(1);
        let mut samples = SampleBuffer::<f32>::new(decoded.capacity() as u64, *decoded.spec());
        samples.copy_interleaved_ref(decoded);
        for frame in samples.samples().chunks(channels) {
            let peak = frame
                .iter()
                .map(|sample| sample.abs())
                .fold(0.0_f32, f32::max);
            block_peak = block_peak.max(peak);
            block_frames += 1;
            if block_frames >= FRAMES_PER_BLOCK {
                blocks.push(block_peak);
                block_peak = 0.0;
                block_frames = 0;
            }
        }
    }
    if block_frames > 0 {
        blocks.push(block_peak);
    }
    if blocks.is_empty() {
        return Ok(vec![0.0; bins]);
    }

    let mut peaks = Vec::with_capacity(bins);
    for index in 0..bins {
        let start = index * blocks.len() / bins;
        let mut end = (index + 1) * blocks.len() / bins;
        if end <= start {
            end = (start + 1).min(blocks.len());
        }
        peaks.push(
            blocks[start.min(blocks.len() - 1)..end]
                .iter()
                .copied()
                .fold(0.0_f32, f32::max),
        );
    }
    let maximum = peaks.iter().copied().fold(0.0_f32, f32::max);
    if maximum > f32::EPSILON {
        for peak in &mut peaks {
            *peak = (*peak / maximum).clamp(0.0, 1.0);
        }
    }
    Ok(peaks)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn codec_detection_is_case_insensitive() {
        assert_eq!(
            codec_from_extension(Path::new("track.FLAC")),
            Some(Codec::Flac)
        );
        assert_eq!(
            codec_from_extension(Path::new("track.Mp3")),
            Some(Codec::Mp3)
        );
    }

    #[test]
    fn extracts_normalized_waveform_from_pcm_wav() {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!("intmusic-waveform-{suffix}.wav"));
        let sample_rate = 8_000_u32;
        let sample_count = sample_rate;
        let data_size = sample_count * 2;
        let mut wav = Vec::with_capacity((44 + data_size) as usize);
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(36 + data_size).to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&16_u32.to_le_bytes());
        wav.extend_from_slice(&1_u16.to_le_bytes());
        wav.extend_from_slice(&1_u16.to_le_bytes());
        wav.extend_from_slice(&sample_rate.to_le_bytes());
        wav.extend_from_slice(&(sample_rate * 2).to_le_bytes());
        wav.extend_from_slice(&2_u16.to_le_bytes());
        wav.extend_from_slice(&16_u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&data_size.to_le_bytes());
        for index in 0..sample_count {
            let sample = if index % 200 < 100 {
                i16::MAX / 2
            } else {
                -(i16::MAX / 2)
            };
            wav.extend_from_slice(&sample.to_le_bytes());
        }
        std::fs::write(&path, wav).expect("write wave fixture");

        let peaks = extract_waveform(&path, 128).expect("extract waveform");
        assert_eq!(peaks.len(), 128);
        assert!(peaks.iter().all(|peak| (0.0..=1.0).contains(peak)));
        assert!(peaks.iter().any(|peak| *peak > 0.9));

        let _ = std::fs::remove_file(path);
    }
}
