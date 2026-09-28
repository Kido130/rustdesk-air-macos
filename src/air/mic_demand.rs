//! Pro-only demand monitoring. No polling or physical capture runs on the Air.
use super::InputOverride;
use hbb_common::{anyhow::{bail, Context}, ResultType};
use std::{sync::{atomic::{AtomicBool, Ordering}, mpsc, Arc}, thread::JoinHandle, time::Duration};
unsafe extern "C" { fn air_mic_demand() -> i32; }
static ROUTE_ACTIVE: AtomicBool = AtomicBool::new(false);

pub(crate) struct NativeMicDemand {
    stop: Option<mpsc::Sender<()>>,
    worker: Option<JoinHandle<()>>,
    active: Arc<AtomicBool>,
}
impl NativeMicDemand {
    pub(crate) fn start(mut notify: impl FnMut(bool) + Send + 'static) -> ResultType<Self> {
        if ROUTE_ACTIVE.compare_exchange(false,true,Ordering::AcqRel,Ordering::Acquire).is_err() {
            bail!("Another remote microphone route is active");
        }
        let result = (|| {
            if unsafe { air_mic_demand() } < 0 { bail!("Microphone demand detection is unavailable"); }
            let route = InputOverride::activate()?;
            let (stop, receiver) = mpsc::channel();
            let active = Arc::new(AtomicBool::new(false));
            let state = active.clone();
            let worker = std::thread::Builder::new().name("air-mic-demand".into()).spawn(move || {
                let _route = route;
                notify(false);
                loop {
                    // Unknown/error is deliberately off, never permission to capture.
                    let demanded = unsafe { air_mic_demand() } == 1;
                    if state.swap(demanded,Ordering::AcqRel) != demanded { notify(demanded); }
                    match receiver.recv_timeout(Duration::from_millis(100)) {
                        Err(mpsc::RecvTimeoutError::Timeout) => {},
                        _ => break,
                    }
                }
                state.store(false,Ordering::Release);
                notify(false);
            }).context("Cannot start microphone demand monitor")?;
            Ok(Self {stop:Some(stop),worker:Some(worker),active})
        })();
        if result.is_err() { ROUTE_ACTIVE.store(false,Ordering::Release); }
        result
    }
    pub(crate) fn active(&self) -> bool { self.active.load(Ordering::Acquire) }
}
impl Drop for NativeMicDemand {
    fn drop(&mut self) {
        self.stop.take();
        if let Some(worker)=self.worker.take() { let _=worker.join(); }
        ROUTE_ACTIVE.store(false,Ordering::Release);
    }
}
