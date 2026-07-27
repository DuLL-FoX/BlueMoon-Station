import { DraftStore } from './drafts';

describe('DraftStore', () => {
  it('держит отдельный черновик на каждый канал', () => {
    const drafts = new DraftStore();
    drafts.save('Me', 'недописанный эмоут');
    drafts.save('Say', 'реплика');

    expect(drafts.load('Me')).toBe('недописанный эмоут');
    expect(drafts.load('Say')).toBe('реплика');
  });

  it('на канале без черновика отдаёт пустую строку', () => {
    const drafts = new DraftStore();

    expect(drafts.load('OOC')).toBe('');
  });

  it('чистит черновик после отправки', () => {
    const drafts = new DraftStore();
    drafts.save('Say', 'реплика');
    drafts.clear('Say');

    expect(drafts.load('Say')).toBe('');
  });

  it('не трогает соседние каналы при очистке', () => {
    const drafts = new DraftStore();
    drafts.save('Say', 'реплика');
    drafts.save('Me', 'эмоут');
    drafts.clear('Say');

    expect(drafts.load('Me')).toBe('эмоут');
  });
});
