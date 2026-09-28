//! Event-driven microphone forwarding; cancellation wins over queued audio.
use hbb_common::tokio::{self, sync::{mpsc, oneshot}};

pub(super) async fn next_packet<T>(
    stop: &mut oneshot::Receiver<()>,
    audio: &mut mpsc::UnboundedReceiver<T>,
) -> Option<T> {
    tokio::select! {
        biased;
        _ = stop => None,
        packet = audio.recv() => packet,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{future::Future, sync::{Arc, atomic::{AtomicUsize, Ordering}}, time::Duration};

    #[tokio::test(start_paused = true)]
    async fn idle_has_no_periodic_wakeups_and_audio_arrival_wakes_immediately() {
        let (_stop_tx, mut stop) = oneshot::channel();
        let (audio_tx, mut audio) = mpsc::unbounded_channel();
        let polls = Arc::new(AtomicUsize::new(0));
        let counted = polls.clone();
        let worker = tokio::spawn(async move {
            let mut pending = Box::pin(next_packet(&mut stop, &mut audio));
            std::future::poll_fn(|cx| {
                counted.fetch_add(1, Ordering::SeqCst);
                pending.as_mut().poll(cx)
            }).await
        });
        tokio::task::yield_now().await;
        assert_eq!(polls.load(Ordering::SeqCst), 1);
        tokio::time::advance(Duration::from_secs(60)).await;
        tokio::task::yield_now().await;
        assert_eq!(polls.load(Ordering::SeqCst), 1);
        audio_tx.send(vec![1, 2, 3]).unwrap();
        assert_eq!(worker.await.unwrap(), Some(vec![1, 2, 3]));
    }

    #[tokio::test]
    async fn cancel_wins_over_backlog_and_closed_stop_cancels() {
        let (stop_tx, mut stop) = oneshot::channel();
        let (audio_tx, mut audio) = mpsc::unbounded_channel();
        audio_tx.send(42).unwrap();
        stop_tx.send(()).unwrap();
        assert_eq!(next_packet(&mut stop, &mut audio).await, None);
        let (stop_tx, mut stop) = oneshot::channel();
        drop(stop_tx);
        assert_eq!(next_packet(&mut stop, &mut audio).await, None);
    }

    #[tokio::test]
    async fn audio_order_is_preserved_and_closed_source_ends_worker() {
        let (_stop_tx, mut stop) = oneshot::channel();
        let (audio_tx, mut audio) = mpsc::unbounded_channel();
        for packet in [11, 12, 13] { audio_tx.send(packet).unwrap(); }
        drop(audio_tx);
        for packet in [11, 12, 13] {
            assert_eq!(next_packet(&mut stop, &mut audio).await, Some(packet));
        }
        assert_eq!(next_packet(&mut stop, &mut audio).await, None);
    }
    #[test]
    fn plain_worker_wakes_for_audio_and_stop_without_tokio_runtime() {
        let (stop_tx, mut stop) = oneshot::channel();
        let (audio_tx, mut audio) = mpsc::unbounded_channel();
        let (observed_tx, observed_rx) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            hbb_common::futures::executor::block_on(async {
                observed_tx.send(next_packet(&mut stop, &mut audio).await).unwrap();
                observed_tx.send(next_packet(&mut stop, &mut audio).await).unwrap();
            });
        });
        audio_tx.send(17).unwrap();
        assert_eq!(observed_rx.recv_timeout(Duration::from_secs(2)).unwrap(), Some(17));
        drop(stop_tx);
        assert_eq!(observed_rx.recv_timeout(Duration::from_secs(2)).unwrap(), None);
        worker.join().unwrap();
    }

}
