//! The JSON messages inside a session (protocol.md, Session messages) and
//! the record envelope (records.md, Envelope).

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// One record as it travels and is stored.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Envelope {
    pub kind: String,
    pub key: String,
    pub version: u64,
    pub seq: u64,
    #[serde(default)]
    pub deleted: bool,
    #[serde(default)]
    pub sort_key: String,
    #[serde(default = "empty_object")]
    pub body: Value,
}

fn empty_object() -> Value {
    Value::Object(Default::default())
}

fn sync_purpose() -> String {
    "sync".into()
}

/// Every message type, both directions. Unknown types parse as `Unknown`
/// and are ignored; unknown fields are ignored.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub(crate) enum Message {
    // Client to host.
    Hello {
        protocol_version: u32,
        schema_version: u32,
        device_id: String,
        #[serde(default)]
        cursor: u64,
        #[serde(default = "sync_purpose")]
        purpose: String,
    },
    Op {
        op: Value,
    },
    Ask {
        request: Value,
    },
    Bye,
    PairRequest {
        device_id: String,
        device_name: String,
        platform: String,
    },

    // Host to client.
    Welcome {
        mac_name: String,
        server_time: String,
        manifest: Option<Value>,
    },
    Records {
        items: Vec<Envelope>,
        last_seq: u64,
        done: bool,
    },
    OpResult {
        op_id: String,
        status: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    AskDelta {
        request_id: String,
        text: String,
    },
    AskDone {
        request_id: String,
        result: Value,
    },
    AskFailed {
        request_id: String,
        message: String,
    },
    Revoked,
    Error {
        code: String,
        message: String,
    },
    PairResult {
        approved: bool,
        mac_name: String,
    },

    // Both directions.
    Ping,
    #[serde(other)]
    Unknown,
}
