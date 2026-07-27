/**
 * @file
 * Черновики по каналам.
 *
 * Недописанный эмоут должен пережить уход в Say и обратно: именно
 * невозможность держать два незаконченных сообщения и была главной претензией
 * к прежнему вводу, где для этого приходилось открывать два окна.
 */

import type { Channel } from './ChannelIterator';

export class DraftStore {
  private drafts: Partial<Record<Channel, string>> = {};

  save(channel: Channel, value: string): void {
    this.drafts[channel] = value;
  }

  load(channel: Channel): string {
    return this.drafts[channel] || '';
  }

  clear(channel: Channel): void {
    delete this.drafts[channel];
  }
}
