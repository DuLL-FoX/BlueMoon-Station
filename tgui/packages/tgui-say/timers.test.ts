import { resetTypingThrottle, shouldSendTyping } from './timers';

describe('троттлинг сигнала набора', () => {
  beforeEach(() => {
    resetTypingThrottle();
  });

  it('пропускает первый сигнал сразу', () => {
    expect(shouldSendTyping(1000)).toBe(true);
  });

  it('глушит частые сигналы: сервер не должен получать по событию на символ', () => {
    expect(shouldSendTyping(1000)).toBe(true);
    expect(shouldSendTyping(1500)).toBe(false);
    expect(shouldSendTyping(3000)).toBe(false);
  });

  it('пропускает сигнал снова, когда окно троттлинга прошло', () => {
    expect(shouldSendTyping(1000)).toBe(true);
    expect(shouldSendTyping(6000)).toBe(true);
  });

  it('после сброса пропускает сигнал немедленно', () => {
    expect(shouldSendTyping(1000)).toBe(true);
    resetTypingThrottle();
    expect(shouldSendTyping(1100)).toBe(true);
  });
});
