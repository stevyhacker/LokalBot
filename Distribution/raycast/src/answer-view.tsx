import { Action, ActionPanel, Detail, Icon, Keyboard } from "@raycast/api";
import { AskSource, describeAskError, revealMeeting } from "./cli";
import type { AnswerState } from "./use-lokalbot-answer";

/** A finished answer or draft can be pasted into the frontmost app or copied. */
export interface ResultAction {
  kind: "paste" | "copy";
  title: string;
}

/** Shared Detail screen for Ask LokalBot and Draft Reply. */
export function AnswerView(props: {
  state: AnswerState;
  loadingMarkdown: string;
  /** Shown above the sources, such as the question asked. */
  labels: { title: string; text: string }[];
  /** The first is the primary action; Try Again and the sources follow. */
  resultActions: ResultAction[];
  retry: () => void;
}) {
  const { state, retry } = props;
  const retryAction = (
    <Action
      title="Try Again"
      icon={Icon.ArrowClockwise}
      shortcut={Keyboard.Shortcut.Common.Refresh}
      onAction={retry}
    />
  );

  if (state.kind === "idle" || state.kind === "loading") {
    return <Detail isLoading markdown={props.loadingMarkdown} />;
  }
  if (state.kind === "failed") {
    return (
      <Detail
        markdown={`## ${state.title}\n\n${state.message}`}
        actions={<ActionPanel>{retryAction}</ActionPanel>}
      />
    );
  }

  const { outcome } = state;
  if (outcome.status === "error") {
    const error = describeAskError(outcome);
    return (
      <Detail
        markdown={`## ${error.title}\n\n${error.message}`}
        actions={
          <ActionPanel>
            {retryAction}
            <Action.Open
              title="Open LokalBot"
              icon={Icon.AppWindow}
              target="/Applications/LokalBot.app"
            />
          </ActionPanel>
        }
      />
    );
  }

  const found = outcome.status === "answered";
  return (
    <Detail
      markdown={outcome.text}
      metadata={
        <Detail.Metadata>
          {props.labels.map((label) => (
            <Detail.Metadata.Label
              key={label.title}
              title={label.title}
              text={label.text}
            />
          ))}
          {outcome.sources.length > 0 ? <Detail.Metadata.Separator /> : null}
          {outcome.sources.map((source: AskSource) => (
            <Detail.Metadata.Label
              key={source.meeting_id}
              title={source.date}
              text={source.title}
              icon={Icon.Microphone}
            />
          ))}
        </Detail.Metadata>
      }
      actions={
        <ActionPanel>
          {found
            ? props.resultActions.map((action) =>
                action.kind === "paste" ? (
                  <Action.Paste
                    key={action.title}
                    title={action.title}
                    content={outcome.text}
                    icon={Icon.Clipboard}
                  />
                ) : (
                  <Action.CopyToClipboard
                    key={action.title}
                    title={action.title}
                    content={outcome.text}
                  />
                ),
              )
            : null}
          {retryAction}
          {outcome.sources.length > 0 ? (
            <ActionPanel.Section title="Sources">
              {outcome.sources.map((source) => (
                <Action
                  key={source.meeting_id}
                  title={`Reveal ${source.title} in Finder`}
                  icon={Icon.Finder}
                  onAction={() => revealMeeting(source.meeting_id)}
                />
              ))}
            </ActionPanel.Section>
          ) : null}
        </ActionPanel>
      }
    />
  );
}
