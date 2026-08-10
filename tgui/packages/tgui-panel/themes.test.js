import { setClientTheme, THEMES } from './themes';

describe('setClientTheme', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    global.Byond = {
      command: jest.fn(),
      winset: jest.fn(),
    };
  });

  afterEach(() => {
    jest.clearAllTimers();
    jest.useRealTimers();
  });

  test.each(THEMES)('%s targets only controls present in the custom skin', theme => {
    setClientTheme(theme);

    expect(Byond.winset).toHaveBeenCalledTimes(1);
    const properties = Byond.winset.mock.calls[0][0];
    expect(Object.hasOwn(properties, 'statwindow.background-color')).toBe(true);
    expect(Object.keys(properties).some(key => key.startsWith('stat.')))
      .toBe(false);
  });
});
