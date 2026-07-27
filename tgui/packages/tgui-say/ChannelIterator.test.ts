import { ChannelIterator } from './ChannelIterator';

describe('ChannelIterator', () => {
  it('крутит короткий цикл Say -> Radio -> Me -> OOC и возвращается к Say', () => {
    const iterator = new ChannelIterator();

    expect(iterator.current()).toBe('Say');
    expect(iterator.next()).toBe('Radio');
    expect(iterator.next()).toBe('Me');
    expect(iterator.next()).toBe('OOC');
    expect(iterator.next()).toBe('Say');
  });

  it('принимает канал вне цикла, но не втягивает его в цикл', () => {
    const iterator = new ChannelIterator();

    iterator.set('Whisper');
    expect(iterator.current()).toBe('Whisper');
    expect(iterator.next()).toBe('Say');
  });

  it('продолжает цикл с того места, куда его поставили', () => {
    const iterator = new ChannelIterator();

    iterator.set('Me');
    expect(iterator.next()).toBe('OOC');
  });

  it('считает OOC-каналы невидимыми, а внутриигровые видимыми', () => {
    const iterator = new ChannelIterator();

    for (const channel of ['OOC', 'LOOC', 'AOOC'] as const) {
      iterator.set(channel);
      expect(iterator.isVisible()).toBe(false);
    }
    for (const channel of ['Say', 'Radio', 'Me', 'Whisper', 'Subtle'] as const) {
      iterator.set(channel);
      expect(iterator.isVisible()).toBe(true);
    }
  });

  it('узнаёт канал Say: только в нём работают префиксы рации', () => {
    const iterator = new ChannelIterator();

    expect(iterator.isSay()).toBe(true);
    iterator.set('Me');
    expect(iterator.isSay()).toBe(false);
  });

  it('игнорирует неизвестный канал вместо того, чтобы сломать переключение', () => {
    const iterator = new ChannelIterator();

    iterator.set('НетТакогоКанала' as any);
    expect(iterator.current()).toBe('Say');
  });

  it('сбрасывается к началу цикла', () => {
    const iterator = new ChannelIterator();

    iterator.set('LOOC');
    iterator.reset();
    expect(iterator.current()).toBe('Say');
  });
});
