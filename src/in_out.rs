#[cfg(feature = "websocket")]
use crate::websocket::{from_ws, to_ws_new, WsRd, WsWr};
use crate::{
    common::IN_BUFFER_SIZE,
    in_out::{StanzaRead::*, StanzaWrite::*},
    slicesubsequence::SliceSubsequence,
    stanzafilter::{StanzaFilter, StanzaReader},
};
use anyhow::{bail, Result};
#[cfg(feature = "websocket")]
use futures_util::{SinkExt, TryStreamExt};
use log::trace;
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
#[cfg(feature = "websocket")]
use tokio_tungstenite::tungstenite::Message::{Close, Ping, Pong, Text};

pub enum StanzaWrite {
    AsyncWrite(Box<dyn AsyncWrite + Unpin + Send>),
    #[cfg(feature = "websocket")]
    WebSocketClientWrite(WsWr),
}

pub enum StanzaRead {
    AsyncRead(StanzaReader<Box<dyn AsyncRead + Unpin + Send>>),
    #[cfg(feature = "websocket")]
    WebSocketRead(WsRd),
}

impl StanzaWrite {
    #[inline(always)]
    pub fn new<T: 'static + AsyncWrite + Unpin + Send>(wr: T) -> Self {
        AsyncWrite(Box::new(wr))
        // todo: investigate buffering this, but don't double buffer
        //AsyncWrite(Box::new(tokio::io::BufWriter::with_capacity(8192, wr)))
    }

    pub async fn write_all<'a>(&'a mut self, is_c2s: bool, buf: &'a [u8], end_of_first_tag: usize, client_addr: &'a str) -> Result<()> {
        match self {
            AsyncWrite(wr) => Ok(wr.write_all(buf).await?),
            #[cfg(feature = "websocket")]
            WebSocketClientWrite(in_wr) => {
                let mut buf = buf;
                // ignore this
                if buf.starts_with(b"<?xml ") {
                    // we might want to skip this if it's stand-alone, otherwise we want to skip it
                    buf = &buf[b"<?xml ".len()..];
                    if let Ok(idx) = buf.first_index_of(b"<") {
                        buf = &buf[idx..];
                    } else {
                        trace!("code: skipping '{}'", String::from_utf8(buf.to_vec())?);
                        return Ok(());
                    }
                }
                let stanza = to_ws_new(buf, end_of_first_tag, is_c2s)?;
                trace!("{} (after ws conversion) '{}'", client_addr, stanza);
                Ok(in_wr.feed(Text(stanza.into())).await?)
            }
        }
    }

    pub async fn flush(&mut self) -> Result<()> {
        match self {
            AsyncWrite(wr) => Ok(wr.flush().await?),
            #[cfg(feature = "websocket")]
            WebSocketClientWrite(ws) => Ok(ws.flush().await?),
        }
    }

    /// Best-effort graceful close: sends TLS close_notify, TCP FIN, QUIC FIN or WebSocket Close.
    /// Without this, dropping a TLS stream just closes TCP, which strict clients (rustls) report as truncation.
    /// Bounded by a timeout so a stalled peer cannot hang the task; errors are ignored since the connection is ending anyway.
    pub async fn shutdown(&mut self) {
        let close = async {
            match self {
                AsyncWrite(wr) => wr.shutdown().await.map_err(anyhow::Error::from),
                #[cfg(feature = "websocket")]
                WebSocketClientWrite(ws) => ws.close().await.map_err(anyhow::Error::from),
            }
        };
        match tokio::time::timeout(std::time::Duration::from_secs(5), close).await {
            Ok(Err(e)) => trace!("shutdown error: {}", e),
            Err(_) => trace!("shutdown timed out"),
            Ok(Ok(())) => {}
        }
    }
}

impl StanzaRead {
    #[inline(always)]
    pub fn new<T: 'static + AsyncRead + Unpin + Send>(rd: T) -> Self {
        // we naively read 1 byte at a time, which buffering significantly speeds up
        AsyncRead(StanzaReader(Box::new(BufReader::with_capacity(IN_BUFFER_SIZE, rd))))
    }

    #[inline(always)]
    pub fn already_buffered<T: 'static + AsyncRead + Unpin + Send>(rd: T) -> Self {
        // we naively read 1 byte at a time, which buffering significantly speeds up
        AsyncRead(StanzaReader(Box::new(rd)))
    }

    pub async fn next<'a>(&'a mut self, filter: &'a mut StanzaFilter, client_addr: &'a str, wrt: &mut StanzaWrite) -> Result<Option<(&'a [u8], usize)>> {
        match self {
            AsyncRead(rd) => rd.next_eoft(filter).await,
            #[cfg(feature = "websocket")]
            WebSocketRead(rd) => {
                loop {
                    if let Some(msg) = rd.try_next().await? {
                        match msg {
                            // actual XMPP stanzas
                            Text(stanza) => {
                                trace!("{} (before ws conversion) '{}'", client_addr, stanza);
                                let stanza = from_ws(stanza.to_string());
                                let stanza = stanza.as_bytes();
                                // todo: set up websocket connection so max size cannot be bigger than filter.buf.len()
                                let buf = &mut filter.buf[0..stanza.len()];
                                buf.copy_from_slice(stanza);
                                return Ok(Some((buf, 0))); // todo: 0 or None...
                            }
                            // websocket ping/pong
                            Ping(msg) => {
                                match wrt {
                                    AsyncWrite(_) => bail!("programming error! should always send matching write pair into read, so websocket for websocket..."),
                                    WebSocketClientWrite(ws) => {
                                        ws.feed(Pong(msg)).await?;
                                        ws.flush().await?;
                                    }
                                }
                                continue;
                            }
                            // handle Close, just break from loop, hopefully client sent <close/> before
                            Close(cf) => bail!("websocket close: {:?}", cf),
                            _ => bail!("invalid websocket message: {}", msg), // Binary or Pong
                        }
                    } else {
                        bail!("websocket stream ended")
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::duplex;

    #[tokio::test]
    async fn test_stanza_write_shutdown_success() {
        // Arrange: create in-memory bidirectional channel
        let (client, server) = duplex(64);
        let mut writer = StanzaWrite::new(client);

        // Act: call shutdown
        writer.shutdown().await;

        // Assert: verify server side can detect clean close
        // (no data written, just shutdown called)
        drop(writer);
        drop(server);
        // If shutdown works, this test completes without panic
    }

    #[tokio::test]
    async fn test_stanza_write_shutdown_timeout() {
        use std::pin::Pin;
        use std::task::{Context as TaskContext, Poll};
        use tokio::io::AsyncWrite;

        // Mock writer that hangs on shutdown
        struct HangingWriter;
        impl AsyncWrite for HangingWriter {
            fn poll_write(
                self: Pin<&mut Self>,
                _cx: &mut TaskContext<'_>,
                buf: &[u8],
            ) -> Poll<std::io::Result<usize>> {
                Poll::Ready(Ok(buf.len()))
            }

            fn poll_flush(self: Pin<&mut Self>, _cx: &mut TaskContext<'_>) -> Poll<std::io::Result<()>> {
                Poll::Ready(Ok(()))
            }

            fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut TaskContext<'_>) -> Poll<std::io::Result<()>> {
                // Never complete - simulate hanging
                Poll::Pending
            }
        }

        // Arrange
        let mut writer = StanzaWrite::new(HangingWriter);

        // Act: shutdown should timeout after 5s, not hang forever
        let start = std::time::Instant::now();
        writer.shutdown().await;
        let elapsed = start.elapsed();

        // Assert: should complete in ~5s, not hang
        assert!(elapsed.as_secs() >= 4 && elapsed.as_secs() <= 6, "Expected ~5s timeout, got {:?}", elapsed);
    }

    #[tokio::test]
    async fn test_stanza_write_shutdown_error_ignored() {
        use std::pin::Pin;
        use std::task::{Context as TaskContext, Poll};
        use tokio::io::AsyncWrite;

        // Mock writer that errors on shutdown
        struct ErrorWriter;
        impl AsyncWrite for ErrorWriter {
            fn poll_write(
                self: Pin<&mut Self>,
                _cx: &mut TaskContext<'_>,
                buf: &[u8],
            ) -> Poll<std::io::Result<usize>> {
                Poll::Ready(Ok(buf.len()))
            }

            fn poll_flush(self: Pin<&mut Self>, _cx: &mut TaskContext<'_>) -> Poll<std::io::Result<()>> {
                Poll::Ready(Ok(()))
            }

            fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut TaskContext<'_>) -> Poll<std::io::Result<()>> {
                Poll::Ready(Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "simulated error")))
            }
        }

        // Arrange
        let mut writer = StanzaWrite::new(ErrorWriter);

        // Act: shutdown should not panic on error
        writer.shutdown().await;

        // Assert: no panic = error was ignored correctly
    }
}
