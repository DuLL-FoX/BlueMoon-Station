/** A browser event received from a BYOND TGUI window. */
export type BrowserEvent<TPayload = unknown> = {
  type: string;
  payload?: TPayload;
  [key: string]: unknown;
};

type DispatchBrowserEvent = (event: BrowserEvent) => unknown;
type ParseBrowserEvent = (rawMessage: string) => BrowserEvent;

type BrowserEventDispatcherOptions = {
  parse?: ParseBrowserEvent;
  record?: (rawMessage: string) => void;
};

/**
 * Owns the browser-side boundary between raw BYOND messages and Redux events.
 * Early messages have already been recorded by tgui-setup, so queue draining
 * deliberately skips the diagnostic recorder while live messages use it.
 */
export class BrowserEventDispatcher {
  private readonly dispatch: DispatchBrowserEvent;
  private readonly parse: ParseBrowserEvent;
  private readonly record?: (rawMessage: string) => void;

  constructor(
    dispatch: DispatchBrowserEvent,
    options: BrowserEventDispatcherOptions = {},
  ) {
    this.dispatch = dispatch;
    this.parse = options.parse || Byond.parseJson;
    this.record = options.record || window.__recordIncomingTguiMessage__;
  }

  dispatchLive = (rawMessage: string): unknown => {
    this.record?.(rawMessage);
    return this.dispatch(this.parse(rawMessage));
  };

  drain(queue: string[]): number {
    let dispatched = 0;
    while (queue.length > 0) {
      const rawMessage = queue.shift();
      if (!rawMessage) {
        break;
      }
      this.dispatch(this.parse(rawMessage));
      dispatched += 1;
    }
    return dispatched;
  }
}
