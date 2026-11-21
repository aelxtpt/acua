use crate::{Client, Error, RequestOptions, Result};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::os::fd::BorrowedFd;

native_response_object! {
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessagesImage {
    /// The image payload encoded as standard base64.
    #[serde(deserialize_with = "crate::core::deserialize_data")]
    pub data: String,
    pub mime_type: String,
    #[serde(rename = "chatGUID")]
    pub chat_guid: String,
    pub chat_display_name: String,
}
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MessagesReadQuery {
    #[serde(rename = "chatGUID")]
    pub chat_guid: String,
    /// Seconds since 2001-01-01 00:00:00 UTC, inclusive.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub from_date: Option<f64>,
    /// Seconds since 2001-01-01 00:00:00 UTC, exclusive.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub to_date: Option<f64>,
    pub unread_only: bool,
    pub limit: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessagesPage {
    pub chats: Vec<MessagesChatReference>,
    pub senders: Vec<MessagesSenderReference>,
    pub messages: Vec<MessagesMessage>,
    pub next_cursor: Option<String>,
}
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MessagesSearchQuery {
    pub text: String,
    #[serde(rename = "chatGUIDs")]
    pub chat_guids: Vec<String>,
    pub participants: Vec<String>,
    pub exact_participants: bool,
    /// Seconds since 2001-01-01 00:00:00 UTC, inclusive.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub from_date: Option<f64>,
    /// Seconds since 2001-01-01 00:00:00 UTC, exclusive.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub to_date: Option<f64>,
    pub limit: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessagesChatReference {
    pub local_ref: String,
    pub guid: String,
    pub display_name: String,
}
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MessagesFindChatsQuery {
    pub participants: Vec<String>,
    pub exact_participants: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Seconds since 2001-01-01 00:00:00 UTC, inclusive.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub from_date: Option<f64>,
    /// Seconds since 2001-01-01 00:00:00 UTC, exclusive.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub to_date: Option<f64>,
    pub unread_only: bool,
    pub limit: i64,
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessagesChatsPage {
    pub chats: Vec<MessagesChat>,
    pub participants: Vec<MessagesSenderReference>,
    pub has_more: bool,
}
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessagesChat {
    pub guid: String,
    pub display_name: String,
    pub service: String,
    /// Seconds since 2001-01-01 00:00:00 UTC.
    pub last_message_date: f64,
    /// Local references into `MessagesChatsPage::participants`.
    pub participants: Vec<String>,
    #[serde(default, deserialize_with = "crate::core::deserialize_optional_i64")]
    pub unread_count: Option<i64>,
}
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessagesChatSearchPage {
    pub chats: Vec<MessagesChatMetadata>,
    pub has_more: bool,
}
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessagesChatMetadata {
    pub guid: String,
    pub display_name: String,
}
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessagesSenderReference {
    pub local_ref: String,
    pub handle: String,
    pub name: Option<String>,
    /// The service's wire name, including values added by newer systems.
    pub service: Option<String>,
}
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessagesMessage {
    pub chat: String,
    pub sender: String,
    pub body: Option<String>,
    /// Seconds since 2001-01-01 00:00:00 UTC.
    pub date: f64,
    pub attachments: Option<Vec<MessagesAttachment>>,
    pub is_unread: Option<bool>,
}
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessagesAttachment {
    pub id: String,
    pub filename: Option<String>,
    pub mime_type: Option<String>,
    #[serde(default, deserialize_with = "crate::core::deserialize_optional_i64")]
    pub size_bytes: Option<i64>,
}
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MessagesActivityInterval {
    Total,
    Day,
    Week,
    Month,
    Year,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MessagesActivityChatType {
    Direct,
    Group,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MessagesActivityBreakdown {
    Overall,
    Chat,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MessagesActivityRank {
    Total,
    Sent,
    Received,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MessagesActivityQuery {
    /// Seconds since 2001-01-01 00:00:00 UTC, inclusive.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub from_date: Option<f64>,
    /// Seconds since 2001-01-01 00:00:00 UTC, exclusive.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub to_date: Option<f64>,
    pub interval: MessagesActivityInterval,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chat_type: Option<MessagesActivityChatType>,
    #[serde(rename = "chatGUIDs")]
    pub chat_guids: Vec<String>,
    pub breakdown: MessagesActivityBreakdown,
    pub rank_by: MessagesActivityRank,
    pub chat_limit: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct MessagesActivityRange {
    /// Seconds since 2001-01-01 00:00:00 UTC, inclusive.
    pub from: f64,
    /// Seconds since 2001-01-01 00:00:00 UTC, exclusive.
    pub to: f64,
}
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct MessagesActivityCount {
    #[serde(deserialize_with = "crate::core::deserialize_i64")]
    pub total: i64,
    #[serde(deserialize_with = "crate::core::deserialize_i64")]
    pub sent: i64,
    #[serde(deserialize_with = "crate::core::deserialize_i64")]
    pub received: i64,
}
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessagesOverallActivity {
    #[serde(flatten)]
    pub count: MessagesActivityCount,
    pub counts_by_bucket: Vec<MessagesActivityCount>,
}
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessagesChatActivity {
    pub guid: String,
    pub display_name: String,
    pub service: String,
    #[serde(rename = "type")]
    pub chat_type: MessagesActivityChatType,
    /// Local references into `MessagesActivityPage::participants`.
    pub participants: Vec<String>,
    #[serde(flatten)]
    pub count: MessagesActivityCount,
    pub counts_by_bucket: Vec<MessagesActivityCount>,
}
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessagesActivityPage {
    pub breakdown: MessagesActivityBreakdown,
    pub range: MessagesActivityRange,
    pub interval: MessagesActivityInterval,
    pub time_zone_identifier: String,
    pub buckets: Vec<MessagesActivityRange>,
    #[serde(deserialize_with = "crate::core::deserialize_i64")]
    pub matching_chat_count: i64,
    pub overall_activity: Option<MessagesOverallActivity>,
    pub chats: Option<Vec<MessagesChatActivity>>,
    pub participants: Option<Vec<MessagesSenderReference>>,
    pub next_cursor: Option<String>,
}
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MessagesSendAttachment {
    pub filename: String,
}
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MessagesPrepareSendQuery {
    #[serde(rename = "chatGUID", skip_serializing_if = "Option::is_none")]
    pub chat_guid: Option<String>,
    pub recipients: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    pub attachments: Vec<MessagesSendAttachment>,
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessagesPreparedSend {
    #[serde(rename = "planID")]
    pub plan_id: String,
    #[serde(rename = "chatGUID")]
    pub chat_guid: Option<String>,
    pub display_name: String,
    pub text: Option<String>,
    pub attachments: Vec<MessagesSendAttachment>,
}
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MessagesCommitSendQuery {
    #[serde(rename = "planID")]
    pub plan_id: String,
    /// Approved text. A plan without attachments requires text here.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MessagesSendDestinationKind {
    ExistingChat,
    NewDirectMessage,
    NewGroupMessage,
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct MessagesSendParticipant {
    pub handle: String,
    pub name: Option<String>,
    pub service: Option<String>,
}
}

native_response_object! {
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessagesSendResult {
    pub destination_kind: MessagesSendDestinationKind,
    #[serde(rename = "chatGUID")]
    pub chat_guid: Option<String>,
    pub display_name: String,
    pub participants: Vec<MessagesSendParticipant>,
    pub service: Option<String>,
    pub text: Option<String>,
    pub attachments: Vec<MessagesSendAttachment>,
    /// Seconds since 2001-01-01 00:00:00 UTC.
    pub sent_at: f64,
}
}

impl Client {
    /// Resolves a destination and prepares an expiring send plan.
    pub fn prepare_messages_send(
        &mut self,
        query: &MessagesPrepareSendQuery,
    ) -> Result<MessagesPreparedSend> {
        self.request("ComputerUseIPCMessagesPrepareSendRequest", query)
    }

    /// Commits the prepared plan once. Pass one readable regular file per
    /// prepared attachment, in the same order, up to 64 files.
    ///
    /// The service seeks the files to the beginning to stage them.
    /// A transport error or uncertain outcome does not imply delivery failed.
    pub fn commit_messages_send(
        &mut self,
        query: &MessagesCommitSendQuery,
        files: &[BorrowedFd<'_>],
    ) -> Result<MessagesSendResult> {
        self.request_with_files(
            "ComputerUseIPCMessagesCommitSendRequest",
            query,
            &RequestOptions::default(),
            files,
        )
    }

    pub fn find_messages_chats(
        &mut self,
        query: &MessagesFindChatsQuery,
    ) -> Result<MessagesChatsPage> {
        validate_date_bounds(query.from_date, query.to_date)?;
        self.request("ComputerUseIPCMessagesFindChatsRequest", query)
    }

    pub fn search_messages_chats(
        &mut self,
        query: &str,
        limit: i64,
    ) -> Result<MessagesChatSearchPage> {
        self.request(
            "ComputerUseIPCMessagesSearchChatsRequest",
            json!({"query": query, "limit": limit}),
        )
    }

    pub fn read_messages(&mut self, query: &MessagesReadQuery) -> Result<MessagesPage> {
        validate_date_bounds(query.from_date, query.to_date)?;
        self.request("ComputerUseIPCMessagesReadMessagesRequest", query)
    }

    pub fn search_messages(&mut self, query: &MessagesSearchQuery) -> Result<MessagesPage> {
        validate_date_bounds(query.from_date, query.to_date)?;
        self.request("ComputerUseIPCMessagesSearchMessagesRequest", query)
    }

    pub fn count_messages_activity(
        &mut self,
        query: &MessagesActivityQuery,
    ) -> Result<MessagesActivityPage> {
        validate_date_bounds(query.from_date, query.to_date)?;
        self.request("ComputerUseIPCMessagesCountActivityRequest", query)
    }

    pub fn read_messages_image(&mut self, attachment_id: &str) -> Result<MessagesImage> {
        self.request(
            "ComputerUseIPCMessagesReadImageRequest",
            json!({"id": attachment_id}),
        )
    }
}

fn validate_date_bounds(from: Option<f64>, to: Option<f64>) -> Result<()> {
    if [from, to]
        .into_iter()
        .flatten()
        .any(|date| !date.is_finite())
    {
        return Err(Error::InvalidInput(
            "Messages date bounds must be finite".into(),
        ));
    }
    Ok(())
}
