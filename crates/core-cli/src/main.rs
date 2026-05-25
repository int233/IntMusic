use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::{Args, Parser, Subcommand};
use core_config::{CoreConfig, CorePaths};
use reqwest::Client;
use serde_json::{json, Value};
use tracing_subscriber::{fmt, EnvFilter};

#[derive(Debug, Parser)]
#[command(name = "local-music-core")]
#[command(
    version,
    about = "Headless local music library core and management CLI"
)]
struct Cli {
    #[arg(
        long,
        env = "INTMUSIC_CORE_URL",
        default_value = "http://127.0.0.1:49330"
    )]
    core_url: String,

    #[arg(long)]
    config: Option<PathBuf>,

    #[arg(long)]
    data_dir: Option<PathBuf>,

    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    Serve,
    Status,
    Diagnostics,
    Scan {
        #[command(subcommand)]
        command: ScanCommand,
    },
    Library {
        #[command(subcommand)]
        command: LibraryCommand,
    },
    Outputs {
        #[command(subcommand)]
        command: OutputsCommand,
    },
    Playback {
        #[command(subcommand)]
        command: PlaybackCommand,
    },
    Pairing {
        #[command(subcommand)]
        command: PairingCommand,
    },
    Db {
        #[command(subcommand)]
        command: DbCommand,
    },
}

#[derive(Debug, Subcommand)]
enum ScanCommand {
    Start,
    Stop,
}

#[derive(Debug, Subcommand)]
enum LibraryCommand {
    Add { path: PathBuf },
    Remove { id: i64 },
    List,
}

#[derive(Debug, Subcommand)]
enum OutputsCommand {
    List,
}

#[derive(Debug, Subcommand)]
enum PlaybackCommand {
    Play(TrackArg),
    Pause,
    Stop,
}

#[derive(Debug, Args)]
struct TrackArg {
    track_id: Option<i64>,
}

#[derive(Debug, Subcommand)]
enum PairingCommand {
    Code,
}

#[derive(Debug, Subcommand)]
enum DbCommand {
    Migrate,
    Backup { path: PathBuf },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Serve => serve(cli.config, cli.data_dir).await,
        Command::Status => print_get(&cli.core_url, "/status").await,
        Command::Diagnostics => print_get(&cli.core_url, "/diagnostics").await,
        Command::Scan { command } => match command {
            ScanCommand::Start => print_post(&cli.core_url, "/scan/start", json!({})).await,
            ScanCommand::Stop => {
                println!("scan stop is reserved; current scanner finishes the active file safely");
                Ok(())
            }
        },
        Command::Library { command } => match command {
            LibraryCommand::Add { path } => {
                print_post(&cli.core_url, "/library/roots", json!({ "path": path })).await
            }
            LibraryCommand::Remove { id } => {
                print_delete(&cli.core_url, &format!("/library/roots/{id}")).await
            }
            LibraryCommand::List => print_get(&cli.core_url, "/library/roots").await,
        },
        Command::Outputs { command } => match command {
            OutputsCommand::List => print_get(&cli.core_url, "/outputs").await,
        },
        Command::Playback { command } => match command {
            PlaybackCommand::Play(track) => {
                print_post(
                    &cli.core_url,
                    "/zones/local/play",
                    json!({ "track_id": track.track_id }),
                )
                .await
            }
            PlaybackCommand::Pause => {
                print_post(&cli.core_url, "/zones/local/pause", json!({})).await
            }
            PlaybackCommand::Stop => {
                print_post(&cli.core_url, "/zones/local/stop", json!({})).await
            }
        },
        Command::Pairing { command } => match command {
            PairingCommand::Code => {
                println!("pairing code flow is reserved for the auth phase");
                Ok(())
            }
        },
        Command::Db { command } => match command {
            DbCommand::Migrate => migrate(cli.config, cli.data_dir).await,
            DbCommand::Backup { path } => backup_db(cli.config, cli.data_dir, path).await,
        },
    }
}

async fn serve(config_override: Option<PathBuf>, data_dir_override: Option<PathBuf>) -> Result<()> {
    let paths = CorePaths::discover(config_override, data_dir_override)?;
    let config = CoreConfig::load_or_create(&paths)?;
    init_logging(&config.logging.level);
    let pool = core_api::initialize_database(&paths, &config).await?;
    core_api::serve(config, paths, pool).await
}

async fn migrate(
    config_override: Option<PathBuf>,
    data_dir_override: Option<PathBuf>,
) -> Result<()> {
    let paths = CorePaths::discover(config_override, data_dir_override)?;
    let config = CoreConfig::load_or_create(&paths)?;
    init_logging(&config.logging.level);
    let pool = core_api::initialize_database(&paths, &config).await?;
    pool.close().await;
    println!("database migrated: {}", paths.database_file.display());
    Ok(())
}

async fn backup_db(
    config_override: Option<PathBuf>,
    data_dir_override: Option<PathBuf>,
    backup_path: PathBuf,
) -> Result<()> {
    let paths = CorePaths::discover(config_override, data_dir_override)?;
    if let Some(parent) = backup_path.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    tokio::fs::copy(&paths.database_file, &backup_path)
        .await
        .with_context(|| format!("failed to copy database to {}", backup_path.display()))?;
    println!("database backed up to {}", backup_path.display());
    Ok(())
}

async fn print_get(core_url: &str, path: &str) -> Result<()> {
    let url = api_url(core_url, path);
    let value = Client::new()
        .get(url)
        .send()
        .await?
        .error_for_status()?
        .json::<Value>()
        .await?;
    println!("{}", serde_json::to_string_pretty(&value)?);
    Ok(())
}

async fn print_post(core_url: &str, path: &str, body: Value) -> Result<()> {
    let url = api_url(core_url, path);
    let value = Client::new()
        .post(url)
        .json(&body)
        .send()
        .await?
        .error_for_status()?
        .json::<Value>()
        .await?;
    println!("{}", serde_json::to_string_pretty(&value)?);
    Ok(())
}

async fn print_delete(core_url: &str, path: &str) -> Result<()> {
    let url = api_url(core_url, path);
    let value = Client::new()
        .delete(url)
        .send()
        .await?
        .error_for_status()?
        .json::<Value>()
        .await?;
    println!("{}", serde_json::to_string_pretty(&value)?);
    Ok(())
}

fn api_url(core_url: &str, path: &str) -> String {
    format!(
        "{}/api/v1{}",
        core_url.trim_end_matches('/'),
        path.strip_prefix('/')
            .map(|path| format!("/{path}"))
            .unwrap_or_else(|| format!("/{path}"))
    )
}

fn init_logging(level: &str) {
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new(level))
        .add_directive("lofty=error".parse().expect("valid lofty log directive"))
        .add_directive(
            "symphonia=warn"
                .parse()
                .expect("valid symphonia log directive"),
        )
        .add_directive("rodio=warn".parse().expect("valid rodio log directive"));
    fmt().with_env_filter(filter).init();
}
