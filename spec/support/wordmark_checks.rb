module WordmarkChecks
  def expect_nanum_square_round_wordmark
    loaded = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      document.fonts.load('800 32px "NanumSquareRound"', 'QuickFlow').then(() => {
        done([...document.fonts].some(face => face.family.replace(/["']/g, '') === 'NanumSquareRound' && face.weight === '800' && face.status === 'loaded'));
      }).catch(() => done(false));
    JS
    expect(loaded).to be(true)
    expect(page.evaluate_script("getComputedStyle(document.querySelector('.app-brand')).fontFamily")).to include("NanumSquareRound")
    expect(page.evaluate_script("getComputedStyle(document.querySelector('.app-brand')).fontWeight")).to eq("800")
    page.driver.browser.execute_cdp("DOM.enable")
    page.driver.browser.execute_cdp("CSS.enable")
    root = page.driver.browser.execute_cdp("DOM.getDocument").fetch("root").fetch("nodeId")
    node = page.driver.browser.execute_cdp("DOM.querySelector", nodeId: root, selector: ".app-brand").fetch("nodeId")
    fonts = page.driver.browser.execute_cdp("CSS.getPlatformFontsForNode", nodeId: node).fetch("fonts")
    expect(fonts).not_to be_empty
    expect(fonts).to all(include("isCustomFont" => true))
    expect(fonts.map { |font| font.fetch("familyName") }).to all(start_with("NanumSquareRound"))
    resources = page.evaluate_script("performance.getEntriesByType('resource').filter(r => r.initiatorType === 'css').map(r => r.name)")
    expect(page.evaluate_script("getComputedStyle(document.body).fontFamily")).not_to include("NanumSquareRound")
    expect(page.evaluate_script(<<~JS)).to be(true)
      (() => {
        const brand = document.querySelector('.app-brand'), box = brand.getBoundingClientRect();
        const range = document.createRange();
        range.selectNodeContents(brand);
        const text = range.getBoundingClientRect();
        return text.left >= box.left - 1 && text.right <= box.right + 1 &&
          text.left >= 0 && text.right <= innerWidth && text.top >= box.top - 1 && text.bottom <= box.bottom + 1;
      })()
    JS
    expect(resources.grep(/comic-neue|ComicNeue/)).to be_empty
    expect(resources.grep(/fonts\.googleapis\.com|fonts\.gstatic\.com/)).to be_empty
  end

  def save_brand_evidence(name)
    return unless ENV["QF_BRAND_EVIDENCE"]

    page.save_screenshot(File.join(ENV.fetch("QF_BRAND_EVIDENCE"), "#{name}.png"))
  end
end
