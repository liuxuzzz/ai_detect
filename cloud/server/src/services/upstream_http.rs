use anyhow::{anyhow, ensure, Context};
use reqwest::{Client, Url};
use std::net::{IpAddr, SocketAddr};

pub(crate) fn api_endpoint(base: &str, endpoint: &str) -> anyhow::Result<Url> {
    let mut url = Url::parse(base.trim()).map_err(|_| anyhow!("渠道地址无效"))?;
    ensure!(
        matches!(url.scheme(), "http" | "https")
            && url.username().is_empty()
            && url.password().is_none(),
        "渠道地址必须是 HTTP(S) 且不包含凭据"
    );
    let path = url.path().trim_end_matches('/');
    let prefix = path
        .strip_suffix("/chat/completions")
        .or_else(|| path.strip_suffix("/responses"))
        .or_else(|| path.strip_suffix("/models"))
        .unwrap_or(path);
    let prefix = if prefix.is_empty() && path.is_empty() {
        "/v1"
    } else {
        prefix
    };
    url.set_path(&format!("{prefix}/{endpoint}"));
    url.set_fragment(None);
    Ok(url)
}

pub(crate) async fn public_client(url: &Url) -> anyhow::Result<(Client, Vec<SocketAddr>)> {
    let host = url
        .host_str()
        .context("渠道缺少域名")?
        .trim_matches(['[', ']']);
    let port = url.port_or_known_default().context("渠道缺少端口")?;
    let addresses: Vec<_> = tokio::net::lookup_host((host, port))
        .await
        .map_err(|_| anyhow!("无法解析渠道域名"))?
        .collect();
    ensure!(
        !addresses.is_empty() && addresses.iter().all(|address| public_ip(address.ip())),
        "云端渠道必须解析到公网地址"
    );
    let client = Client::builder()
        .connect_timeout(std::time::Duration::from_secs(45))
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .resolve_to_addrs(host, &addresses)
        .build()?;
    Ok((client, addresses))
}

fn public_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => {
            let [first, second, third, _] = ip.octets();
            !matches!(
                (first, second, third),
                (0 | 10 | 127 | 224..=255, _, _)
                    | (100, 64..=127, _)
                    | (169, 254, _)
                    | (172, 16..=31, _)
                    | (192, 0, 0 | 2)
                    | (192, 88, 99)
                    | (192, 168, _)
                    | (198, 18 | 19, _)
                    | (198, 51, 100)
                    | (203, 0, 113)
            )
        }
        IpAddr::V6(ip) => {
            let [first, second, ..] = ip.segments();
            (0x2000..=0x3fff).contains(&first)
                && first != 0x2002
                && !(first == 0x2001 && (second < 0x0200 || second == 0x0db8))
                && first != 0x3fff
        }
    }
}

#[cfg(test)]
mod tests {
    use super::api_endpoint;

    #[test]
    fn resolves_models_next_to_inference_endpoints() {
        for (base, path) in [
            ("https://example.test", "/v1/models"),
            ("https://example.test/v1/", "/v1/models"),
            (
                "https://example.test/gateway/openai/v1/chat/completions",
                "/gateway/openai/v1/models",
            ),
            (
                "https://example.test/gateway/openai/v1/responses/",
                "/gateway/openai/v1/models",
            ),
        ] {
            assert_eq!(api_endpoint(base, "models").unwrap().path(), path);
        }
        let url = api_endpoint(
            "https://example.test/v1/chat/completions?tenant=test#fragment",
            "responses",
        )
        .unwrap();
        assert_eq!(url.path(), "/v1/responses");
        assert_eq!(url.query(), Some("tenant=test"));
        assert!(url.fragment().is_none());
    }
}
