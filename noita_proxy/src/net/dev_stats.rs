//! Numbers for the in-game dev overlay. The mod asks for them with `dev_stats 1`
//! while its overlay is shown, and gets one `dev_stats` message per second back.

use std::fmt::Write;
use std::time::{Duration, Instant};

use super::omni::PeerVariant;
use super::steam_networking::PerPeerStatus;

const REPORT_INTERVAL: Duration = Duration::from_secs(1);

pub(crate) struct DevStats {
    window_start: Instant,
    /// Longest proxy loop iteration (excluding the idle sleep) in this window.
    max_tick: Duration,
    world_bytes_to_game: usize,
    world_msgs_to_game: usize,
    des_msgs_out: usize,
}

impl Default for DevStats {
    fn default() -> Self {
        Self {
            window_start: Instant::now(),
            max_tick: Duration::ZERO,
            world_bytes_to_game: 0,
            world_msgs_to_game: 0,
            des_msgs_out: 0,
        }
    }
}

impl DevStats {
    pub(crate) fn on_world_update_to_game(&mut self, len: usize) {
        self.world_bytes_to_game += len;
        self.world_msgs_to_game += 1;
    }

    pub(crate) fn on_des_msgs_out(&mut self, count: usize) {
        self.des_msgs_out += count;
    }

    pub(crate) fn on_tick(&mut self, took: Duration) {
        self.max_tick = self.max_tick.max(took);
    }

    /// Returns the message value once per second, then starts a new window.
    ///
    /// Format: `<tick_max_us>:<world_bytes>:<world_msgs>:<des_msgs> <peers>`, where
    /// `<peers>` is `-` or `;`-separated `hex,ping_ms,loc_q,rem_q,in_bps,out_bps,pend_rel,unacked`.
    /// Fields that the connection type can't report are `-`. Values carry no spaces,
    /// since the mod splits proxy messages on spaces.
    pub(crate) fn take_report(&mut self, peer: &PeerVariant) -> Option<String> {
        let elapsed = self.window_start.elapsed();
        if elapsed < REPORT_INTERVAL {
            return None;
        }
        let secs = elapsed.as_secs_f64();
        let mut out = format!(
            "{}:{}:{}:{} ",
            self.max_tick.as_micros(),
            (self.world_bytes_to_game as f64 / secs) as u64,
            (self.world_msgs_to_game as f64 / secs) as u64,
            (self.des_msgs_out as f64 / secs) as u64,
        );
        let mut peers = Vec::new();
        match peer {
            PeerVariant::Steam(steam) => {
                for entry in steam.generate_report().per_peer_statuses {
                    let mut s = entry.peer.as_hex();
                    match entry.status {
                        PerPeerStatus::Connected { realtimeinfo: i } => {
                            let _ = write!(
                                s,
                                ",{},{:.0},{:.0},{:.0},{:.0},{},{}",
                                i.ping(),
                                i.connection_quality_local() * 100.0,
                                i.connection_quality_remote() * 100.0,
                                i.in_bytes_per_sec(),
                                i.out_bytes_per_sec(),
                                i.pending_reliable(),
                                i.sent_unacked_reliable(),
                            );
                        }
                        _ => s.push_str(",-,-,-,-,-,-,-"),
                    }
                    peers.push(s);
                }
            }
            PeerVariant::Tangled(_) => {
                let me = peer.my_id();
                for id in peer.iter_peer_ids() {
                    if id != me {
                        peers.push(format!("{},-,-,-,-,-,-,-", id.as_hex()));
                    }
                }
            }
        }
        if peers.is_empty() {
            out.push('-');
        } else {
            out.push_str(&peers.join(";"));
        }
        *self = Self::default();
        Some(out)
    }
}
