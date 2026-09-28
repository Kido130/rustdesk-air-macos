//! Source-linked monitor test with deterministic demand and input-route substitutes.
extern crate self as hbb_common;
pub use anyhow;
pub type ResultType<T> = anyhow::Result<T>;
use std::sync::atomic::{AtomicI32, AtomicUsize, Ordering};
static DEMAND: AtomicI32 = AtomicI32::new(0);
static ROUTES: AtomicUsize = AtomicUsize::new(0);
struct InputOverride;
impl InputOverride {
    fn activate() -> ResultType<Self> { ROUTES.fetch_add(1,Ordering::SeqCst); Ok(Self) }
}
impl Drop for InputOverride { fn drop(&mut self) { ROUTES.fetch_sub(1,Ordering::SeqCst); } }
#[no_mangle]
extern "C" fn air_mic_demand() -> i32 { DEMAND.load(Ordering::SeqCst) }
#[path = "../mic_demand.rs"] mod production;
#[test]
fn demand_starts_stops_fails_closed_and_restores_route() {
    use std::{sync::mpsc, time::Duration};
    let (tx,rx)=mpsc::channel();
    let monitor=production::NativeMicDemand::start(move |v| { let _=tx.send(v); }).unwrap();
    assert_eq!(ROUTES.load(Ordering::SeqCst),1);
    assert!(!rx.recv_timeout(Duration::from_secs(2)).unwrap());
    assert!(!monitor.active());
    assert!(production::NativeMicDemand::start(|_|{}).is_err());
    assert!(rx.recv_timeout(Duration::from_millis(220)).is_err());
    DEMAND.store(1,Ordering::SeqCst);
    assert!(rx.recv_timeout(Duration::from_secs(2)).unwrap());
    assert!(monitor.active());
    DEMAND.store(-1,Ordering::SeqCst);
    assert!(!rx.recv_timeout(Duration::from_secs(2)).unwrap());
    assert!(!monitor.active());
    DEMAND.store(1,Ordering::SeqCst);
    assert!(rx.recv_timeout(Duration::from_secs(2)).unwrap());
    drop(monitor);
    assert!(!rx.recv_timeout(Duration::from_secs(2)).unwrap());
    assert_eq!(ROUTES.load(Ordering::SeqCst),0);
    DEMAND.store(-1,Ordering::SeqCst);
    assert!(production::NativeMicDemand::start(|_|{}).is_err());
    assert_eq!(ROUTES.load(Ordering::SeqCst),0);
    DEMAND.store(0,Ordering::SeqCst);
    drop(production::NativeMicDemand::start(|_|{}).unwrap());
    assert_eq!(ROUTES.load(Ordering::SeqCst),0);
}
