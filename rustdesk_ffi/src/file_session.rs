//! RustDesk file work reuses a logged-in file connection per session.
//!
//! Every file job used to open its own connection: rendezvous, key exchange and login for each folder opened, each
//! upload and each check after it. Now a session keeps two lanes, each with at most one connection:
//! - Control: listing, folder trees, new folders, removing and renaming (short requests);
//! - Data: uploads and downloads, so browsing stays responsive while a file transfers.
//!
//! A lane runs its jobs one after another on its connection and keeps the connection only after a job that finished
//! cleanly: after a failure or a cancel, late replies of that job could be mistaken for the next one's, so the
//! connection is dropped and the next job logs in again. While idle, the lane answers the peer's probes (the peer
//! closes a session that sends nothing for 30 s) and closes the connection after `LANE_IDLE`.

use std::collections::HashMap;
use std::io;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender, TryRecvError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::connector::RustDeskConnector;
use crate::file_transfer::{FileOperation, TransferJob};

/// A lane without work closes its connection and ends after this long.
const LANE_IDLE: Duration = if cfg!(test) { Duration::from_millis(600) } else { Duration::from_secs(90) };
const LANE_TICK: Duration = if cfg!(test) { Duration::from_millis(50) } else { Duration::from_millis(500) };

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub(crate) enum FileLaneKind {
    Control,
    Data,
}

impl FileLaneKind {
    pub(crate) fn for_operation(operation: &FileOperation) -> Self {
        match operation {
            FileOperation::Upload { .. } | FileOperation::Download(_) => Self::Data,
            _ => Self::Control,
        }
    }
}

/// One job for a lane. `reservation` keeps the job's connect epoch admitted until the job ends (or, for the job
/// that opened the connection, until the connection closes).
pub(crate) struct FileCommand {
    pub job: Arc<TransferJob>,
    pub operation: FileOperation,
    pub path: String,
    pub remote_dir: String,
    pub reservation: Option<crate::ConnectEpochReservation>,
}

/// How a lane opens its connection and runs a job on it; production uses the RustDesk connector, tests a fake.
pub(crate) trait FileLaneBackend: Send + 'static {
    type Connection: Send + 'static;
    fn connect(&self, job: &TransferJob, epoch: u64, remote_dir: &str) -> io::Result<Self::Connection>;
    /// Runs the job; `Ok(true)` keeps the connection for the next job.
    fn run(&self, connection: &mut Self::Connection, command: &mut FileCommand) -> io::Result<bool>;
    /// Answers probes while idle; an error closes the connection.
    fn pump_idle(&self, connection: &mut Self::Connection) -> io::Result<()>;
}

struct LaneConnection<C> {
    connection: C,
    /// The connect epoch the connection was opened under; a cancelled session cancels it.
    reservation: crate::ConnectEpochReservation,
}

struct LaneHandle {
    sender: Sender<FileCommand>,
    generation: u64,
}

type LaneMap = Arc<Mutex<HashMap<FileLaneKind, LaneHandle>>>;

static LANE_GENERATION: AtomicU64 = AtomicU64::new(0);

#[derive(Default)]
pub(crate) struct FileLanes {
    lanes: LaneMap,
}

impl FileLanes {
    /// Queues the command on the lane of its kind, starting the lane when none runs. A lane only ends while holding
    /// the lane map, after checking its queue is empty, so a command queued here is never left unread.
    pub(crate) fn dispatch<B: FileLaneBackend>(&self, backend: B, command: FileCommand) -> io::Result<()> {
        let kind = FileLaneKind::for_operation(&command.operation);
        let mut lanes = self
            .lanes
            .lock()
            .map_err(|_| io::Error::other("file lane lock"))?;
        let command = match lanes.get(&kind) {
            Some(handle) => match handle.sender.send(command) {
                Ok(()) => return Ok(()),
                Err(mpsc::SendError(command)) => command,
            },
            None => command,
        };
        let (sender, receiver) = mpsc::channel::<FileCommand>();
        let generation = LANE_GENERATION.fetch_add(1, Ordering::SeqCst).wrapping_add(1);
        let map = Arc::clone(&self.lanes);
        std::thread::Builder::new()
            .name(format!("rustdesk-file-{:?}", kind).to_lowercase())
            .spawn(move || run_lane(backend, kind, generation, receiver, map))?;
        sender
            .send(command)
            .map_err(|_| io::Error::other("file lane start"))?;
        lanes.insert(kind, LaneHandle { sender, generation });
        Ok(())
    }
}

fn run_lane<B: FileLaneBackend>(
    backend: B,
    kind: FileLaneKind,
    generation: u64,
    receiver: Receiver<FileCommand>,
    lanes: LaneMap,
) {
    let mut connection: Option<LaneConnection<B::Connection>> = None;
    let mut idle_since = Instant::now();
    loop {
        match receiver.recv_timeout(LANE_TICK) {
            Ok(command) => {
                connection = execute(&backend, connection, command);
                idle_since = Instant::now();
            }
            Err(RecvTimeoutError::Timeout) => {
                if let Some(open) = connection.as_mut() {
                    if crate::connect_cancelled(open.reservation.epoch())
                        || backend.pump_idle(&mut open.connection).is_err()
                    {
                        connection = None;
                    }
                }
                if idle_since.elapsed() < LANE_IDLE {
                    continue;
                }
                let Ok(mut map) = lanes.lock() else {
                    return;
                };
                match receiver.try_recv() {
                    Ok(command) => {
                        drop(map);
                        connection = execute(&backend, connection, command);
                        idle_since = Instant::now();
                    }
                    Err(_) => {
                        if map.get(&kind).is_some_and(|handle| handle.generation == generation) {
                            map.remove(&kind);
                        }
                        return;
                    }
                }
            }
            Err(RecvTimeoutError::Disconnected) => return,
        }
    }
}

/// Runs one command. Returns the connection to keep for the next command, if any.
fn execute<B: FileLaneBackend>(
    backend: &B,
    mut connection: Option<LaneConnection<B::Connection>>,
    mut command: FileCommand,
) -> Option<LaneConnection<B::Connection>> {
    let job = Arc::clone(&command.job);
    let epoch = command.reservation.as_ref().map(|r| r.epoch()).unwrap_or(0);
    job.bind_epoch(epoch);
    // Time spent queued behind another job is not idle time of this one.
    job.progress(0);
    if connection
        .as_ref()
        .is_some_and(|open| crate::connect_cancelled(open.reservation.epoch()))
    {
        connection = None;
    }
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> io::Result<bool> {
        job.check()?;
        if connection.is_none() {
            let connected = backend.connect(&job, epoch, &command.remote_dir)?;
            // The opening job's epoch now belongs to the connection (a cancel of that job, or of the session,
            // retires the connection).
            let reservation = command
                .reservation
                .take()
                .ok_or_else(|| io::Error::other("file lane admission"))?;
            connection = Some(LaneConnection { connection: connected, reservation });
        }
        let open = connection.as_mut().expect("lane connection");
        backend.run(&mut open.connection, &mut command)
    }))
    .unwrap_or_else(|_| Err(io::Error::other("file lane worker panic")));
    let keep = matches!(result, Ok(true));
    job.finish(result.map(|_| ()));
    if !keep {
        connection = None;
    }
    connection
}

/// Production backend: the RustDesk file connection.
pub(crate) struct ConnectorBackend {
    pub connect: Arc<dyn Fn(&TransferJob, u64, &str) -> io::Result<RustDeskConnector> + Send + Sync>,
}

impl FileLaneBackend for ConnectorBackend {
    type Connection = RustDeskConnector;

    fn connect(&self, job: &TransferJob, epoch: u64, remote_dir: &str) -> io::Result<RustDeskConnector> {
        (self.connect)(job, epoch, remote_dir)
    }

    fn run(&self, connector: &mut RustDeskConnector, command: &mut FileCommand) -> io::Result<bool> {
        crate::run_file_operation(connector, command)
    }

    fn pump_idle(&self, connector: &mut RustDeskConnector) -> io::Result<()> {
        connector.pump_idle_file_channel()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::file_transfer::TransferRegistry;
    use std::sync::atomic::AtomicUsize;

    #[derive(Clone, Default)]
    struct Fake {
        connects: Arc<AtomicUsize>,
        runs: Arc<Mutex<Vec<(usize, String)>>>,
        fail_paths: Arc<Mutex<Vec<String>>>,
    }

    impl FileLaneBackend for Fake {
        type Connection = usize;
        fn connect(&self, _job: &TransferJob, _epoch: u64, _remote_dir: &str) -> io::Result<usize> {
            Ok(self.connects.fetch_add(1, Ordering::SeqCst) + 1)
        }
        fn run(&self, connection: &mut usize, command: &mut FileCommand) -> io::Result<bool> {
            self.runs.lock().unwrap().push((*connection, command.path.clone()));
            if self.fail_paths.lock().unwrap().contains(&command.path) {
                return Err(io::Error::other("fake failure"));
            }
            Ok(true)
        }
        fn pump_idle(&self, _connection: &mut usize) -> io::Result<()> {
            Ok(())
        }
    }

    fn command(registry: &mut TransferRegistry, id: u64, path: &str) -> (Arc<TransferJob>, FileCommand) {
        let job = registry.insert(id, 0).unwrap();
        let command = FileCommand {
            job: Arc::clone(&job),
            operation: FileOperation::List { include_hidden: false },
            path: path.to_owned(),
            remote_dir: String::new(),
            reservation: Some(crate::ConnectEpochReservation::new(9_000_001)),
        };
        (job, command)
    }

    fn wait_terminal(job: &TransferJob) -> u32 {
        for _ in 0..200 {
            let state = job.status.lock().unwrap().0.state;
            if state != 2 {
                return state;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        2
    }

    #[test]
    fn file_lane_reuses_one_connection_and_reconnects_after_a_failure() {
        let fake = Fake::default();
        fake.fail_paths.lock().unwrap().push("/bad".to_owned());
        let lanes = FileLanes::default();
        let mut registry = TransferRegistry::default();
        for (id, path) in [(1, "/a"), (2, "/b"), (3, "/bad"), (4, "/c")] {
            let (job, command) = command(&mut registry, id, path);
            lanes.dispatch(fake.clone(), command).unwrap();
            let state = wait_terminal(&job);
            assert_eq!(state, if path == "/bad" { 4 } else { 6 }, "{path}");
            registry.release(id);
        }
        let runs = fake.runs.lock().unwrap().clone();
        assert_eq!(runs.iter().map(|(c, _)| *c).collect::<Vec<_>>(), vec![1, 1, 1, 2]);
        assert_eq!(fake.connects.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn file_lane_ends_when_idle_and_a_later_job_starts_a_new_one() {
        let fake = Fake::default();
        let lanes = FileLanes::default();
        let mut registry = TransferRegistry::default();
        let (job, first) = command(&mut registry, 1, "/a");
        lanes.dispatch(fake.clone(), first).unwrap();
        assert_eq!(wait_terminal(&job), 6);
        std::thread::sleep(LANE_IDLE + Duration::from_millis(400));
        assert!(lanes.lanes.lock().unwrap().is_empty());
        let (job, second) = command(&mut registry, 2, "/b");
        lanes.dispatch(fake.clone(), second).unwrap();
        assert_eq!(wait_terminal(&job), 6);
        assert_eq!(fake.connects.load(Ordering::SeqCst), 2);
    }
}
