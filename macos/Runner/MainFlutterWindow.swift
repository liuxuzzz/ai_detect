import Cocoa
import FlutterMacOS
import WebKit

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.minSize = NSSize(width: 1120, height: 720)
    var initialFrame = windowFrame
    initialFrame.size = NSSize(width: max(windowFrame.width, 1440), height: max(windowFrame.height, 900))
    self.setFrame(initialFrame, display: true)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)
    let registrar = flutterViewController.registrar(forPlugin: "HtmlPreview")
    registrar.register(
      HtmlPreviewFactory(messenger: registrar.messenger),
      withId: "aijiance/html-preview"
    )

    super.awakeFromNib()
  }
}

private class HtmlPreviewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
    return FlutterStandardMessageCodec.sharedInstance()
  }

  func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
    let values = args as? [String: Any]
    return HtmlPreviewWebView(
      html: values?["html"] as? String ?? "",
      viewId: viewId,
      messenger: messenger
    )
  }
}

// WKUserContentController retains its message handler. Keep the view weak so
// closing a preview releases its browser and Flutter channel.
private class HtmlPreviewSizeHandler: NSObject, WKScriptMessageHandler {
  weak var preview: HtmlPreviewWebView?

  func userContentController(_ userContentController: WKUserContentController,
                            didReceive message: WKScriptMessage) {
    preview?.receiveSize(message)
  }
}

private class HtmlPreviewWebView: WKWebView {
  private var channel: FlutterMethodChannel?
  private var generation = 0
  private var reportedHeight: Double = 0

  init(html: String, viewId: Int64, messenger: FlutterBinaryMessenger) {
    let configuration = WKWebViewConfiguration()
    // Every preview uses its own temporary browser storage.
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
    let sizeHandler = HtmlPreviewSizeHandler()
    configuration.userContentController.add(sizeHandler, name: "previewSize")
    super.init(frame: .zero, configuration: configuration)
    sizeHandler.preview = self
    allowsBackForwardNavigationGestures = false
    channel = FlutterMethodChannel(
      name: "aijiance/html-preview/\(viewId)", binaryMessenger: messenger
    )
    channel?.setMethodCallHandler { [weak self] call, result in
      guard call.method == "loadHtml", let html = call.arguments as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.loadPreview(html)
      result(nil)
    }
    loadPreview(html)
  }

  private func loadPreview(_ html: String) {
    generation += 1
    reportedHeight = 0
    let controller = configuration.userContentController
    controller.removeAllUserScripts()
    controller.addUserScript(WKUserScript(
      source: "(function(){const generation=\(generation);\n" + Self.resizeScript + "\n})();",
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true
    ))
    loadHTMLString(html, baseURL: nil)
  }

  fileprivate func receiveSize(_ message: WKScriptMessage) {
    guard message.frameInfo.isMainFrame,
          let value = message.body as? [String: Any],
          let version = (value["generation"] as? NSNumber)?.intValue,
          version == generation,
          let height = (value["height"] as? NSNumber)?.doubleValue,
          height.isFinite, height > 0,
          abs(height - reportedHeight) >= 1 else { return }
    reportedHeight = height
    channel?.invokeMethod("contentHeight", arguments: height)
  }

  // The preview expands inside Flutter's output scroller; it never owns a
  // separate vertical scroll position, including when the mouse is over HTML.
  override func scrollWheel(with event: NSEvent) {
    nextResponder?.scrollWheel(with: event)
  }

  private static let resizeScript = #"""
    const style=document.createElement('style');
    style.textContent='html,body{height:auto!important;min-height:0!important;max-height:none!important;overflow:visible!important}';
    (document.head||document.documentElement).appendChild(style);
    let pending=false;
    function measure(){
      pending=false;
      const body=document.body;
      if(!body)return;
      // Expand explicit vertical scroll panels too, keeping horizontal layout.
      for(const element of body.querySelectorAll('*')){
        const css=getComputedStyle(element);
        if(/^(auto|scroll)$/.test(css.overflowY) && element.scrollHeight>element.clientHeight+1){
          element.style.setProperty('height','auto','important');
          element.style.setProperty('min-height','0','important');
          element.style.setProperty('max-height','none','important');
          element.style.setProperty('overflow-y','visible','important');
        }
      }
      const box=body.getBoundingClientRect();
      const margin=parseFloat(getComputedStyle(body).marginBottom)||0;
      const height=Math.max(1,Math.ceil(Math.max(body.scrollHeight,body.offsetHeight,box.height)+Math.max(0,box.top)+margin));
      window.webkit.messageHandlers.previewSize.postMessage({generation,height});
    }
    function schedule(){if(!pending){pending=true;requestAnimationFrame(measure);}}
    new ResizeObserver(schedule).observe(document.body);
    new MutationObserver(schedule).observe(document.documentElement,{subtree:true,childList:true,attributes:true,characterData:true});
    window.addEventListener('resize',schedule);
    window.addEventListener('load',schedule,true);
    if(document.fonts)document.fonts.ready.then(schedule);
    schedule();
    """#

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    channel?.setMethodCallHandler(nil)
  }
}
