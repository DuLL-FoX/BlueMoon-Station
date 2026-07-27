/**
 * @file
 * История отправленных сообщений: стрелка вверх достаёт предыдущее.
 *
 * Курсор ноль означает, что игрок не листает историю, а пишет новое
 * сообщение. Недописанный текст при этом сохраняется отдельно, чтобы возврат
 * вниз вернул именно его, а не пустое поле.
 */

const DEFAULT_LIMIT = 25;

export class ChatHistory {
  private messages: string[] = [];
  private index = 0;
  private temp = '';

  constructor(private limit: number = DEFAULT_LIMIT) {}

  /** Запомнить отправленное сообщение. */
  add(message: string): void {
    if (!message || !message.trim().length) {
      return;
    }
    // Повтор подряд засоряет историю: человек часто отправляет одно и то же
    // дважды, а листать потом приходится через дубликаты.
    if (this.messages[0] !== message) {
      this.messages.unshift(message);
      if (this.messages.length > this.limit) {
        this.messages.length = this.limit;
      }
    }
    this.reset();
  }

  /** Сообщение старше текущего. На самом старом остаётся на месте. */
  getOlderMessage(): string | null {
    if (!this.messages.length) {
      return null;
    }
    if (this.index < this.messages.length) {
      this.index++;
    }
    return this.messages[this.index - 1];
  }

  /** Сообщение свежее текущего. За границей истории возвращает null. */
  getNewerMessage(): string | null {
    if (this.index <= 1) {
      this.index = 0;
      return null;
    }
    this.index--;
    return this.messages[this.index - 1];
  }

  /** Сохранить недописанный текст перед уходом в историю. */
  saveTemp(value: string): void {
    this.temp = value;
  }

  getTemp(): string {
    return this.temp;
  }

  /** Листает ли игрок историю прямо сейчас. */
  isAtLatest(): boolean {
    return this.index === 0;
  }

  /** Позиция в истории, считая с единицы. Ноль — история не листается. */
  getIndex(): number {
    return this.index;
  }

  /** Вернуть курсор к новому сообщению, сами сообщения оставить. */
  reset(): void {
    this.index = 0;
    this.temp = '';
  }
}
