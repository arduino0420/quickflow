module WordmarkChecks
  def expect_nunito_wordmark
    loaded = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      document.fonts.load('800 32px Nunito', 'QuickFlow').then(() => {
        done([...document.fonts].some(face => face.family === 'Nunito' && face.weight === '800' && face.status === 'loaded'));
      }).catch(() => done(false));
    JS
    expect(loaded).to be(true)
    expect(page.evaluate_script("getComputedStyle(document.querySelector('.app-brand')).fontFamily")).to start_with("Nunito")
    expect(page.evaluate_script("getComputedStyle(document.querySelector('.app-brand')).fontWeight")).to eq("800")
    page.driver.browser.execute_cdp("DOM.enable")
    page.driver.browser.execute_cdp("CSS.enable")
    root = page.driver.browser.execute_cdp("DOM.getDocument").fetch("root").fetch("nodeId")
    node = page.driver.browser.execute_cdp("DOM.querySelector", nodeId: root, selector: ".app-brand").fetch("nodeId")
    fonts = page.driver.browser.execute_cdp("CSS.getPlatformFontsForNode", nodeId: node).fetch("fonts")
    expect(fonts).not_to be_empty
    expect(fonts).to all(include("isCustomFont" => true))
    expect(fonts.map { |font| font.fetch("familyName") }).to all(start_with("Nunito"))
    resources = page.evaluate_script("performance.getEntriesByType('resource').filter(r => r.initiatorType === 'css').map(r => r.name)")
    expect(resources.grep(/fonts\.googleapis\.com|fonts\.gstatic\.com/)).to be_empty
  end

  def save_brand_evidence(name)
    return unless ENV["QF_BRAND_EVIDENCE"]

    page.save_screenshot(File.join(ENV.fetch("QF_BRAND_EVIDENCE"), "#{name}.png"))
  end
end
