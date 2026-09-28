use super::Pairing;
use hbb_common::{
    anyhow::{anyhow, Context}, bail, protobuf::Message as _, sodiumoxide::crypto::sign,
    tokio, ResultType, Stream,
};
use base::message_proto::{message, Message, PublicKey};
use std::{net::{IpAddr, SocketAddr}, path::Path, process::Command};

pub(super) fn advertised(port: u16) -> (Vec<String>, Vec<String>) {
    let default_name = default_net::get_default_interface().ok().map(|interface| interface.name);
    let interfaces = default_net::get_interfaces();
    let mut lan = ranked_lan_routes(interfaces.iter().flat_map(|interface| {
        if interface.flags & hbb_common::libc::IFF_UP as u32 == 0 { return Vec::new(); }
        interface.ipv4.iter().filter(|address| address.addr.is_private())
            .map(|address| (interface.name.clone(), address.addr.to_string()))
            .collect::<Vec<_>>()
    }), default_name.as_deref(), port);
    if let Ok(result) = Command::new("/usr/sbin/scutil").args(["--get", "LocalHostName"]).output() {
        let name = String::from_utf8_lossy(&result.stdout).trim().to_owned();
        if result.status.success() && !name.is_empty()
            && name.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-') {
            lan.push(format!("{name}.local:{port}"));
        }
    }
    let mut tailscale = Vec::new();
    // Read the local interface addresses, so pairing export does not need to
    // launch a CLI, log in, or contact a third-party service.
    for interface in interfaces {
        if interface.flags & hbb_common::libc::IFF_UP as u32 == 0 { continue; }
        for address in interface.ipv4 {
            let octets = address.addr.octets();
            if octets[0] == 100 && (64..=127).contains(&octets[1]) {
                let candidate = format!("{}:{port}", address.addr);
                if !tailscale.contains(&candidate) { tailscale.push(candidate); }
            }
        }
        for address in interface.ipv6 {
            if address.addr.segments()[..3] == [0xfd7a, 0x115c, 0xa1e0] {
                let candidate = format!("[{}]:{port}", address.addr);
                if !tailscale.contains(&candidate) { tailscale.push(candidate); }
            }
        }
    }
    tailscale.sort();
    (lan, tailscale)
}

fn ranked_lan_routes(routes: impl IntoIterator<Item = (String, String)>,
    default_name: Option<&str>, port: u16) -> Vec<String> {
    let mut ranked = Vec::new();
    for (name, ip) in routes {
        let Some(suffix) = name.strip_prefix("en") else { continue; };
        if suffix.is_empty() || !suffix.bytes().all(|c| c.is_ascii_digit()) { continue; }
        let Ok(ip) = ip.parse::<std::net::Ipv4Addr>() else { continue; };
        if !ip.is_private() { continue; }
        ranked.push((if default_name == Some(name.as_str()) { 0 } else { 1 }, ip));
    }
    ranked.sort_unstable();
    ranked.dedup();
    let mut addresses = Vec::new();
    for (_, ip) in ranked {
        let address = format!("{ip}:{port}");
        if !addresses.contains(&address) { addresses.push(address); }
    }
    addresses
}

// A .local name alone does not prove the machine has a usable LAN interface.
pub(super) fn refresh_routes(pairing: &mut Pairing, port: u16,
    lan: Vec<String>, tailscale: Vec<String>) -> bool {
    let mut private_lan = Vec::new();
    let mut local_names = Vec::new();
    for address in lan {
        if !valid(&address) || address.rsplit_once(':')
            .and_then(|(_, value)| value.parse::<u16>().ok()) != Some(port) { continue; }
        if address.parse::<SocketAddr>().ok().is_some_and(|socket| {
            matches!(socket.ip(), IpAddr::V4(ip) if ip.is_private())
        }) {
            if !private_lan.contains(&address) { private_lan.push(address); }
        } else if address.ends_with(&format!(".local:{port}")) && !local_names.contains(&address) {
            local_names.push(address);
        }
    }
    let mut tailscale_routes = Vec::new();
    for address in tailscale {
        if valid(&address) && is_tailscale(&address)
            && address.parse::<SocketAddr>().ok().is_some_and(|socket| socket.port() == port)
            && !tailscale_routes.contains(&address) { tailscale_routes.push(address); }
    }
    let Some(address) = private_lan.first().or_else(|| tailscale_routes.first()).cloned() else {
        return false;
    };
    if !private_lan.is_empty() { private_lan.extend(local_names); }
    private_lan.truncate(32);
    tailscale_routes.truncate(16);
    if pairing.address == address && pairing.lan_addresses == private_lan
        && pairing.tailscale_addresses == tailscale_routes { return false; }
    pairing.address = address;
    pairing.lan_addresses = private_lan;
    pairing.tailscale_addresses = tailscale_routes;
    true
}

fn valid(address: &str) -> bool {
    if address.len() > 255 || address.chars().any(char::is_whitespace) { return false; }
    if let Ok(socket) = address.parse::<SocketAddr>() {
        return socket.port() != 0 && !socket.ip().is_unspecified() && !socket.ip().is_multicast();
    }
    let Some((host, port)) = address.rsplit_once(':') else { return false; };
    if port.parse::<u16>().ok().filter(|p| *p != 0).is_none() { return false; }
    !host.is_empty() && host.len() <= 253 && host.split('.').all(|label| {
        !label.is_empty() && label.len() <= 63 && !label.starts_with('-') && !label.ends_with('-')
            && label.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-')
    })
}

fn is_tailscale(address: &str) -> bool {
    let Ok(socket) = address.parse::<SocketAddr>() else { return false; };
    match socket.ip() {
        IpAddr::V4(ip) => ip.octets()[0] == 100 && (64..=127).contains(&ip.octets()[1]),
        IpAddr::V6(ip) => ip.segments()[..3] == [0xfd7a, 0x115c, 0xa1e0],
    }
}

pub(super) fn candidates(pairing: &Pairing) -> Vec<String> {
    let mut lan = Vec::new();
    let mut tailscale = Vec::new();
    for address in std::iter::once(&pairing.address)
        .chain(pairing.lan_addresses.iter().take(32))
        .chain(pairing.tailscale_addresses.iter().take(16)) {
        if !valid(address) { continue; }
        let group = if is_tailscale(address) { &mut tailscale } else { &mut lan };
        if !group.contains(address) { group.push(address.clone()); }
    }
    lan.truncate(8);
    tailscale.truncate(4);
    lan.extend(tailscale);
    lan
}

pub(super) async fn connect(pairing: &Pairing) -> ResultType<(Stream, Vec<u8>)> {
    let key = hex::decode(&pairing.public_key)?;
    let signing_key = sign::PublicKey::from_slice(&key).ok_or_else(|| anyhow!("Invalid paired public key"))?;
    let saved = candidates(pairing);
    let port = discovery_port(pairing);
    let result = match connect_addresses(&saved, &pairing.host_id, &signing_key).await {
        Ok(stream) => Ok(stream),
        Err(saved_error) => {
            // The pairing file may predate Tailscale, or its IP may have changed.
            // Inspect only the local tailnet view after every saved LAN route fails.
            let live = match port {
                Some(port) if port != 0 => live_tailscale_addresses(port).await,
                _ => Vec::new(),
            };
            let live: Vec<_> = live.into_iter().filter(|address| !saved.contains(address)).collect();
            if live.is_empty() { Err(saved_error) }
            else {
                // A large tailnet must not make reconnect wait indefinitely.
                match hbb_common::timeout(12_000, connect_addresses_with_policy(&live, &pairing.host_id, &signing_key, false)).await {
                    Ok(Ok(stream)) => Ok(stream),
                    Ok(Err(live_error)) => Err(anyhow!("{saved_error}; live Tailscale routes: {live_error}")),
                    Err(_) => Err(anyhow!("{saved_error}; live Tailscale route search timed out")),
                }
            }
        }
    };
    result
        .map(|stream| (stream, signing_key.0.to_vec()))
}

fn discovery_port(pairing: &Pairing) -> Option<u16> {
    pairing.tailscale_addresses.iter()
        .filter(|address| valid(address) && is_tailscale(address))
        .find_map(|address| address.parse::<SocketAddr>().ok().map(|socket| socket.port()))
        .or_else(|| pairing.address.rsplit_once(':')
            .and_then(|(_, port)| port.parse::<u16>().ok().filter(|port| *port != 0)))
}

fn peer_addresses(status: &[u8], port: u16) -> Vec<String> {
    if port == 0 || status.len() > 1_048_576 { return Vec::new(); }
    let Ok(status) = serde_json::from_slice::<serde_json::Value>(status) else { return Vec::new(); };
    if status.get("BackendState").and_then(|value| value.as_str()) != Some("Running") {
        return Vec::new();
    }
    let Some(peers) = status.get("Peer").and_then(|value| value.as_object()) else { return Vec::new(); };
    let mut addresses = Vec::new();
    for peer in peers.values() {
        if peer.get("Online").and_then(|value| value.as_bool()) == Some(false) { continue; }
        let Some(ips) = peer.get("TailscaleIPs").and_then(|value| value.as_array()) else { continue; };
        for ip in ips {
            let Some(ip) = ip.as_str().and_then(|value| value.parse::<IpAddr>().ok()) else { continue; };
            let address = SocketAddr::new(ip, port).to_string();
            if is_tailscale(&address) && !addresses.contains(&address) { addresses.push(address); }
        }
    }
    // Bound the number of verified TCP attempts even on a large tailnet.
    addresses.truncate(128);
    addresses
}

async fn live_tailscale_addresses(port: u16) -> Vec<String> {
    // Tailscale documents both the standalone launcher and the App Store path.
    // Force CLI mode so the bundled executable cannot open its GUI here.
    for path in ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale"] {
        if !Path::new(path).is_file() { continue; }
        let output = hbb_common::timeout(2000, tokio::process::Command::new(path)
            .env("TAILSCALE_BE_CLI", "1")
            .args(["status", "--json"])
            .kill_on_drop(true)
            .output()).await;
        if let Ok(Ok(output)) = output {
            if output.status.success() { return peer_addresses(&output.stdout, port); }
        }
    }
    Vec::new()
}

async fn connect_addresses(addresses: &[String], host_id: &str, signing_key: &sign::PublicKey) -> ResultType<Stream> {
    connect_addresses_with_policy(addresses, host_id, signing_key, true).await
}

async fn connect_addresses_with_policy(addresses: &[String], host_id: &str,
    signing_key: &sign::PublicKey, fatal_on_identity_failure: bool) -> ResultType<Stream> {
    let mut failures = Vec::new();
    let mut security_failure = false;
    for address in addresses {
        match connect_candidate(address, host_id, signing_key).await {
            Ok(stream) => {
                super::shell::clear_security_failure();
                super::status(&format!("RustDesk Air — encrypted direct connection — {address}"));
                return Ok(stream);
            }
            Err(error) => {
                security_failure |= error.to_string().contains("signed identity")
                    || error.to_string().contains("host identity");
                failures.push(format!("{address}: {error}"));
            }
        }
    }
    // Discovered tailnet peers are untrusted candidates, not claimed matches.
    // A different RustDesk Host on the same tailnet must not poison reconnect.
    if security_failure && fatal_on_identity_failure { super::shell::fatal_security(); }
    bail!("Cannot reach the paired Pro over LAN or Tailscale: {}", failures.join("; "))
}

async fn connect_candidate(address: &str, host_id: &str, signing_key: &sign::PublicKey) -> ResultType<Stream> {
    let socket = hbb_common::timeout(1800, tokio::net::TcpStream::connect(address))
        .await.context("Connection timed out")??;
    socket.set_nodelay(true)?;
    let local = socket.local_addr()?;
    let mut stream = Stream::from(socket, local);
    let packet = hbb_common::timeout(2500, stream.next()).await?
        .ok_or_else(|| anyhow!("Host closed during identity verification"))??;
    let message = Message::parse_from_bytes(&packet).context("Invalid signed identity packet")?;
    let Some(message::Union::SignedId(identity)) = message.union else {
        bail!("Host did not provide a signed identity");
    };
    let (id, ephemeral) = crate::decode_id_pk(&identity.id, signing_key)
        .context("Invalid signed identity")?;
    if id != host_id { bail!("Paired host identity does not match"); }
    let (asymmetric_value, symmetric_value, key) = crate::create_symmetric_key_msg(ephemeral);
    let mut reply = Message::new();
    reply.set_public_key(PublicKey { asymmetric_value, symmetric_value, ..Default::default() });
    hbb_common::timeout(2500, stream.send(&reply)).await??;
    stream.set_key(key);
    if !stream.is_secured() { bail!("Encrypted connection could not be established"); }
    Ok(stream)
}

pub(super) fn self_test() -> ResultType<()> {
    let p = Pairing { version: 1, address: "100.64.0.87:21128".into(),
        lan_addresses: vec!["pro.local:21128".into(), "10.0.0.1:21128".into(), "bad host:0".into(), "[evil]:21128".into()],
        tailscale_addresses: vec!["100.64.0.87:21128".into(), "[fd7a:115c:a1e0::1]:21128".into()],
        host_id: String::new(), public_key: String::new(), password: String::new() };
    if candidates(&p) != ["pro.local:21128", "10.0.0.1:21128", "100.64.0.87:21128", "[fd7a:115c:a1e0::1]:21128"] {
        bail!("LAN-first route ordering/deduplication failed");
    }
    let old: Pairing = serde_json::from_str(r#"{"version":1,"address":"127.0.0.1:21128","host_id":"x","public_key":"x","password":"x"}"#)?;
    if candidates(&old) != ["127.0.0.1:21128"] { bail!("Old pairing compatibility failed"); }
    Ok(())
}

async fn signed_server(signed: Vec<u8>, ephemeral_secret: Option<hbb_common::sodiumoxide::crypto::box_::SecretKey>)
    -> ResultType<(String, tokio::task::JoinHandle<ResultType<()>>)> {
    use base::message_proto::SignedId;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let address = listener.local_addr()?.to_string();
    let task = tokio::spawn(async move {
        let (socket, peer) = listener.accept().await?;
        let mut stream = Stream::from(socket, peer);
        let mut message = Message::new();
        message.set_signed_id(SignedId { id: signed.into(), ..Default::default() });
        stream.send(&message).await?;
        if let Some(secret) = ephemeral_secret {
            let packet = stream.next().await.ok_or_else(|| anyhow!("Missing symmetric-key response"))??;
            let reply = Message::parse_from_bytes(&packet)?;
            let Some(message::Union::PublicKey(key)) = reply.union else {
                bail!("Verified host did not receive the symmetric-key response");
            };
            let symmetric = hbb_common::tcp::Encrypt::decode(
                &key.symmetric_value, &key.asymmetric_value, &secret,
            )?;
            stream.set_key(symmetric);
            if !stream.is_secured() { bail!("Verified host did not enter encrypted mode"); }
        }
        Ok(())
    });
    Ok((address, task))
}

#[tokio::main(flavor = "current_thread")]
pub(super) async fn connection_self_test() -> ResultType<()> {
    use hbb_common::rendezvous_proto::IdPk;
    use hbb_common::sodiumoxide::crypto::box_;
    hbb_common::sodiumoxide::init().map_err(|_| anyhow!("Cannot initialize encryption for network self-test"))?;
    let (pk, sk) = sign::gen_keypair();
    let (ephemeral, ephemeral_secret) = box_::gen_keypair();
    let signed = |id: &str, secret: &sign::SecretKey| -> ResultType<Vec<u8>> {
        Ok(sign::sign(&IdPk {
            id: id.to_owned(), pk: ephemeral.0.to_vec().into(), ..Default::default()
        }.write_to_bytes()?, secret))
    };
    let (wrong, wrong_task) = signed_server(signed("impostor", &sk)?, None).await?;
    let (_, other_sk) = sign::gen_keypair();
    let (wrong_key, wrong_key_task) = signed_server(signed("paired-pro", &other_sk)?, None).await?;
    let (good, good_task) = signed_server(signed("paired-pro", &sk)?, Some(ephemeral_secret)).await?;
    let dead = std::net::TcpListener::bind("127.0.0.1:0")?;
    let dead_address = dead.local_addr()?.to_string();
    drop(dead);
    let pairing = Pairing {
        version: 1, address: dead_address.clone(), lan_addresses: vec![wrong.clone(), wrong_key.clone()],
        tailscale_addresses: vec![good.clone()], host_id: "paired-pro".into(),
        public_key: hex::encode(pk.0), password: "test-only".into(),
    };
    let routes = candidates(&pairing);
    if routes != [dead_address, wrong, wrong_key, good] { bail!("Candidate fallback order changed"); }
    let stream = connect_addresses(&routes, "paired-pro", &pk).await?;
    if !stream.is_secured() { bail!("Fallback stream was not encrypted"); }
    if super::shell::fatal_reason() != 0 { bail!("A rejected route poisoned the verified fallback"); }
    wrong_task.await??;
    wrong_key_task.await??;
    good_task.await??;

    let (wrong, wrong_task) = signed_server(signed("impostor", &sk)?, None).await?;
    let rejected = connect_addresses(&[wrong], "paired-pro", &pk).await;
    if !rejected.as_ref().err().is_some_and(|error| error.to_string().contains("host identity does not match"))
        || super::shell::fatal_reason() != 1 {
        bail!("Wrong paired identity was not rejected");
    }
    wrong_task.await??;
    super::shell::clear_security_failure();
    let (unrelated, unrelated_task) = signed_server(signed("another-tailnet-host", &sk)?, None).await?;
    let rejected = connect_addresses_with_policy(&[unrelated], "paired-pro", &pk, false).await;
    if rejected.is_ok() || super::shell::fatal_reason() != 0 {
        bail!("An unrelated discovered peer poisoned signed reconnect");
    }
    unrelated_task.await??;
    println!("Signed fallback: dead route and wrong identity/key rejected; encrypted host accepted");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{discovery_port, peer_addresses};
    fn pairing() -> super::Pairing {
        super::Pairing {
            version: 1, address: "10.0.0.4:21128".into(),
            lan_addresses: vec!["10.0.0.4:21128".into()],
            tailscale_addresses: vec!["100.64.0.87:21128".into()],
            host_id: "host".into(), public_key: "key".into(), password: "secret".into(),
        }
    }

    #[test]
    fn offline_boot_preserves_routes_then_online_refreshes_without_credentials_change() {
        let mut pairing = pairing();
        let original = pairing.clone();
        assert!(!super::refresh_routes(&mut pairing, 21128,
            vec!["pro.local:21128".into()], Vec::new()));
        assert_eq!(serde_json::to_value(&pairing).unwrap(), serde_json::to_value(&original).unwrap());
        assert!(super::refresh_routes(&mut pairing, 21128,
            vec!["10.0.0.8:21128".into(), "pro.local:21128".into()],
            vec!["100.64.0.91:21128".into()]));
        assert_eq!(pairing.address, "10.0.0.8:21128");
        assert_eq!(pairing.lan_addresses, ["10.0.0.8:21128", "pro.local:21128"]);
        assert_eq!(pairing.tailscale_addresses, ["100.64.0.91:21128"]);
        assert!(super::super::same_pairing_identity(&pairing, &original));
    }

    #[test]
    fn fresh_offline_host_gains_a_lan_route_after_network_returns() {
        let mut pairing = pairing();
        pairing.address = "127.0.0.1:21128".into();
        pairing.lan_addresses.clear();
        pairing.tailscale_addresses.clear();
        assert!(!super::refresh_routes(&mut pairing, 21128,
            vec!["pro.local:21128".into()], Vec::new()));
        assert_eq!(pairing.address, "127.0.0.1:21128");
        assert!(super::refresh_routes(&mut pairing, 21128,
            vec!["10.0.0.8:21128".into(), "pro.local:21128".into()], Vec::new()));
        assert_eq!(pairing.address, "10.0.0.8:21128");
    }

    #[test]
    fn route_changes_only_when_usable_interfaces_change() {
        let mut pairing = pairing();
        assert!(!super::refresh_routes(&mut pairing, 21128, Vec::new(), Vec::new()));
        assert!(!super::refresh_routes(&mut pairing, 21128,
            vec!["127.0.0.1:21128".into(), "pro.local:21128".into()], Vec::new()));
        assert_eq!(pairing.address, "10.0.0.4:21128");
        assert!(super::refresh_routes(&mut pairing, 21128,
            vec!["pro.local:21128".into()], vec!["100.64.0.91:21128".into()]));
        assert_eq!(pairing.address, "100.64.0.91:21128");
        assert!(pairing.lan_addresses.is_empty());
        assert!(!super::refresh_routes(&mut pairing, 21128,
            Vec::new(), vec!["100.64.0.91:21128".into()]));
    }

    #[test]
    fn a_different_pairing_identity_cannot_be_refreshed() {
        let expected = pairing();
        let mut changed = expected.clone();
        changed.password = "different".into();
        assert!(!super::super::same_pairing_identity(&changed, &expected));
        changed = expected.clone();
        changed.host_id = "different".into();
        assert!(!super::super::same_pairing_identity(&changed, &expected));
        changed = expected.clone();
        changed.public_key = "different".into();
        assert!(!super::super::same_pairing_identity(&changed, &expected));
        changed = expected.clone();
        changed.version = 2;
        assert!(!super::super::same_pairing_identity(&changed, &expected));
    }

    #[test]
    fn physical_default_lan_is_first_and_interface_order_is_stable() {
        let routes = vec![
            ("bridge100".into(), "10.200.0.1".into()),
            ("en0".into(), "192.168.1.9".into()),
            ("utun4".into(), "10.9.0.2".into()),
            ("en7".into(), "10.0.0.8".into()),
        ];
        let expected = ["10.0.0.8:21128", "192.168.1.9:21128"];
        assert_eq!(super::ranked_lan_routes(routes.clone(), Some("en7"), 21128), expected);
        assert_eq!(super::ranked_lan_routes(routes.into_iter().rev(), Some("en7"), 21128), expected);
        assert_eq!(super::ranked_lan_routes(vec![("en7".into(), "10.0.0.8".into())],
            Some("utun4"), 21128), ["10.0.0.8:21128"]);
    }
    #[test]
    fn dead_lan_and_wrong_identity_fall_through_to_verified_host() {
        super::connection_self_test().unwrap();
    }
    #[test]
    fn live_peer_discovery_accepts_only_tailscale_addresses_from_running_peers() {
        let status = br#"{"BackendState":"Running","Peer":{"a":{"Online":true,"TailscaleIPs":["100.64.0.88","fd7a:115c:a1e0::7","10.0.0.1","bad"]},"b":{"Online":false,"TailscaleIPs":["100.64.0.89"]},"c":{"TailscaleIPs":["100.64.0.88"]}}}"#;
        assert_eq!(peer_addresses(status, 21128), ["100.64.0.88:21128", "[fd7a:115c:a1e0::7]:21128"]);
        assert!(peer_addresses(status, 0).is_empty());
        assert!(peer_addresses(br#"{"BackendState":"Stopped","Peer":{"a":{"TailscaleIPs":["100.64.0.88"]}}}"#, 21128).is_empty());
        assert!(peer_addresses(b"not JSON", 21128).is_empty());
    }

    #[test]
    fn live_peer_discovery_uses_saved_host_port_after_lan_proxy_loss() {
        let pairing = super::Pairing {
            version: 1, address: "127.0.0.1:60778".into(),
            lan_addresses: vec!["127.0.0.1:60778".into()],
            tailscale_addresses: vec!["100.127.255.253:21128".into()],
            host_id: "paired-pro".into(), public_key: String::new(), password: String::new(),
        };
        assert_eq!(discovery_port(&pairing), Some(21128));
        assert_eq!(peer_addresses(br#"{"BackendState":"Running","Peer":{"pro":{"Online":true,"TailscaleIPs":["100.64.0.87"]}}}"#,
            discovery_port(&pairing).unwrap()), ["100.64.0.87:21128"]);
        let legacy = super::Pairing { tailscale_addresses: Vec::new(), ..pairing };
        assert_eq!(discovery_port(&legacy), Some(60778));
    }
}
