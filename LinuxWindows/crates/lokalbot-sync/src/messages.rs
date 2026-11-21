use serde::{Deserialize, Serialize};
use serde_json::Value;

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

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub(crate) enum Message {
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
    UploadBegin {
        upload_id: String,
        byte_count: u64,
        sha256: String,
        recording: Value,
    },
    UploadChunk {
        upload_id: String,
        offset: u64,
        data: String,
    },
    UploadFinish {
        upload_id: String,
    },
    Bye,
    PairRequest {
        device_id: String,
        device_name: String,
        platform: String,
    },

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
    UploadReady {
        upload_id: String,
        offset: u64,
    },
    UploadAck {
        upload_id: String,
        offset: u64,
    },
    UploadDone {
        upload_id: String,
        status: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        meeting_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        message: Option<String>,
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

    Ping,
    #[serde(other)]
    Unknown,
}
