import { ChatHistory } from './ChatHistory';

describe('ChatHistory', () => {
  it('отдаёт сообщения от свежих к старым и упирается в самое старое', () => {
    const history = new ChatHistory();
    history.add('первое');
    history.add('второе');

    expect(history.getOlderMessage()).toBe('второе');
    expect(history.getOlderMessage()).toBe('первое');
    expect(history.getOlderMessage()).toBe('первое');
  });

  it('возвращает недописанный текст при возврате вниз', () => {
    const history = new ChatHistory();
    history.add('отправленное');
    history.saveTemp('черновик');

    expect(history.getOlderMessage()).toBe('отправленное');
    expect(history.getNewerMessage()).toBeNull();
    expect(history.getTemp()).toBe('черновик');
    expect(history.isAtLatest()).toBe(true);
  });

  it('не заводит вторую запись на подряд идущий повтор', () => {
    const history = new ChatHistory();
    history.add('одно');
    history.add('одно');

    expect(history.getOlderMessage()).toBe('одно');
    expect(history.getOlderMessage()).toBe('одно');
    expect(history.getIndex()).toBe(1);
  });

  it('на пустой истории ничего не отдаёт', () => {
    const history = new ChatHistory();

    expect(history.getOlderMessage()).toBeNull();
    expect(history.getNewerMessage()).toBeNull();
    expect(history.isAtLatest()).toBe(true);
  });

  it('не хранит больше предела', () => {
    const history = new ChatHistory(3);
    history.add('первое');
    history.add('второе');
    history.add('третье');
    history.add('четвёртое');

    expect(history.getOlderMessage()).toBe('четвёртое');
    expect(history.getOlderMessage()).toBe('третье');
    expect(history.getOlderMessage()).toBe('второе');
    expect(history.getOlderMessage()).toBe('второе');
  });

  it('не запоминает пустые строки', () => {
    const history = new ChatHistory();
    history.add('');
    history.add('   ');

    expect(history.getOlderMessage()).toBeNull();
  });

  it('сбрасывает курсор, оставляя сами сообщения', () => {
    const history = new ChatHistory();
    history.add('сообщение');
    history.getOlderMessage();
    history.reset();

    expect(history.isAtLatest()).toBe(true);
    expect(history.getOlderMessage()).toBe('сообщение');
  });
});
