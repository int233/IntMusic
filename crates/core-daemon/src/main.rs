use std::{ffi::OsString, path::PathBuf, sync::OnceLock};

use anyhow::{Context, Result};
use core_config::{CoreConfig, CorePaths};
use tracing_subscriber::{fmt, EnvFilter};

#[cfg(windows)]
use chrono::Utc;
#[cfg(windows)]
use std::{
    backtrace::Backtrace,
    fs::{self, OpenOptions},
    io::Write,
    panic,
    sync::{Arc, Mutex},
};
#[cfg(windows)]
use tokio::sync::oneshot;
#[cfg(windows)]
use windows_service::{
    define_windows_service,
    service::{
        ServiceControl, ServiceControlAccept, ServiceExitCode, ServiceState, ServiceStatus,
        ServiceType,
    },
    service_control_handler::{self, ServiceControlHandlerResult},
    service_dispatcher,
};

#[cfg(windows)]
const SERVICE_NAME: &str = "IntMusicCore";

static RUN_OPTIONS: OnceLock<RunOptions> = OnceLock::new();

#[derive(Clone, Debug, Default)]
struct RunOptions {
    service: bool,
    config: Option<PathBuf>,
    data_dir: Option<PathBuf>,
}

#[cfg(windows)]
define_windows_service!(ffi_service_main, service_main);

fn main() -> Result<()> {
    let options = parse_run_options(std::env::args_os().skip(1))?;
    let _ = RUN_OPTIONS.set(options.clone());

    #[cfg(windows)]
    if options.service {
        service_dispatcher::start(SERVICE_NAME, ffi_service_main)
            .context("failed to start Windows service dispatcher")?;
        return Ok(());
    }

    run_foreground(options)
}

#[cfg(windows)]
fn service_main(_arguments: Vec<OsString>) {
    let options = RUN_OPTIONS.get().cloned().unwrap_or_default();
    install_service_panic_hook(options.clone());
    append_service_log(&options, "service process starting");
    if let Err(error) = run_windows_service() {
        append_service_log(
            &options,
            &format!("service control integration failed: {error:#?}"),
        );
        eprintln!("IntMusicCore service failed: {error:?}");
    }
}

#[cfg(windows)]
fn install_service_panic_hook(options: RunOptions) {
    let previous_hook = panic::take_hook();
    panic::set_hook(Box::new(move |panic_info| {
        append_service_log(
            &options,
            &format!(
                "service panicked: {panic_info}\n{}",
                Backtrace::force_capture()
            ),
        );
        previous_hook(panic_info);
    }));
}

#[cfg(windows)]
fn append_service_log(options: &RunOptions, message: &str) {
    let data_root = options
        .config
        .as_deref()
        .and_then(|path| path.parent())
        .or_else(|| options.data_dir.as_deref().and_then(|path| path.parent()));
    let Some(data_root) = data_root else {
        return;
    };
    if fs::create_dir_all(data_root).is_err() {
        return;
    }
    let log_file = data_root.join("service.log");
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(log_file) {
        let _ = writeln!(file, "[{}] {message}", Utc::now().to_rfc3339());
    }
}

#[cfg(windows)]
fn run_windows_service() -> Result<()> {
    let options = RUN_OPTIONS.get().cloned().unwrap_or_default();
    let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();
    let shutdown_tx = Arc::new(Mutex::new(Some(shutdown_tx)));
    let event_handler_tx = Arc::clone(&shutdown_tx);

    let status_handle =
        service_control_handler::register(
            SERVICE_NAME,
            move |control_event| match control_event {
                ServiceControl::Stop | ServiceControl::Shutdown => {
                    if let Some(sender) = event_handler_tx.lock().ok().and_then(|mut tx| tx.take())
                    {
                        let _ = sender.send(());
                    }
                    ServiceControlHandlerResult::NoError
                }
                ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
                _ => ServiceControlHandlerResult::NotImplemented,
            },
        )?;

    status_handle.set_service_status(service_status(ServiceState::StartPending, 0))?;
    init_logging("info");
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("failed to create Tokio runtime")?;

    status_handle.set_service_status(service_status(ServiceState::Running, 0))?;
    let log_options = options.clone();
    let result = runtime.block_on(run_core(options, async {
        let _ = shutdown_rx.await;
    }));
    match &result {
        Ok(()) => append_service_log(&log_options, "Core shut down cleanly"),
        Err(error) => append_service_log(
            &log_options,
            &format!("Core initialization or runtime failed: {error:#?}"),
        ),
    }
    status_handle.set_service_status(service_status(ServiceState::StopPending, 0))?;

    let exit_code = if result.is_ok() { 0 } else { 1 };
    status_handle.set_service_status(service_status(ServiceState::Stopped, exit_code))?;
    result
}

#[cfg(windows)]
fn service_status(state: ServiceState, exit_code: u32) -> ServiceStatus {
    ServiceStatus {
        service_type: ServiceType::OWN_PROCESS,
        current_state: state,
        controls_accepted: match state {
            ServiceState::Running => ServiceControlAccept::STOP | ServiceControlAccept::SHUTDOWN,
            _ => ServiceControlAccept::empty(),
        },
        exit_code: if exit_code == 0 {
            ServiceExitCode::Win32(0)
        } else {
            ServiceExitCode::ServiceSpecific(exit_code)
        },
        checkpoint: 0,
        wait_hint: std::time::Duration::from_secs(10),
        process_id: None,
    }
}

fn run_foreground(options: RunOptions) -> Result<()> {
    init_logging("info");
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("failed to create Tokio runtime")?;
    runtime.block_on(run_core(options, async {
        let _ = tokio::signal::ctrl_c().await;
    }))
}

async fn run_core<S>(options: RunOptions, shutdown: S) -> Result<()>
where
    S: std::future::Future<Output = ()> + Send + 'static,
{
    let paths = CorePaths::discover(options.config, options.data_dir)?;
    let config = CoreConfig::load_or_create(&paths)?;
    init_logging(&config.logging.level);
    let pool = core_api::initialize_database(&paths, &config).await?;
    core_api::serve_with_shutdown(config, paths, pool, shutdown).await
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
    let _ = fmt().with_env_filter(filter).try_init();
}

fn parse_run_options<I>(args: I) -> Result<RunOptions>
where
    I: IntoIterator<Item = OsString>,
{
    let mut options = RunOptions::default();
    let mut iter = args.into_iter();
    while let Some(arg) = iter.next() {
        let arg = arg.to_string_lossy();
        match arg.as_ref() {
            "--service" => options.service = true,
            "--config" => {
                options.config = Some(
                    iter.next()
                        .map(PathBuf::from)
                        .context("--config requires a path")?,
                );
            }
            "--data-dir" => {
                options.data_dir = Some(
                    iter.next()
                        .map(PathBuf::from)
                        .context("--data-dir requires a path")?,
                );
            }
            "--help" | "-h" => {
                print_help();
                std::process::exit(0);
            }
            value => {
                anyhow::bail!("unknown argument: {value}");
            }
        }
    }
    Ok(options)
}

fn print_help() {
    println!("IntMusic Core daemon");
    println!();
    println!("Usage:");
    println!("  local-music-core-daemon [--service] [--config PATH] [--data-dir PATH]");
}
