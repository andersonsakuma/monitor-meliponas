import UIKit
import WebKit

/// Mostra as mesmas telas do aplicativo Android (pasta www) e oferece a ponte
/// `window.Android` com os mesmos nomes de funções. Chamadas que precisam de
/// resposta imediata passam por prompt() (resposta síncrona no WKWebView).
final class TelaPrincipal: UIViewController, WKUIDelegate, WKNavigationDelegate {
    private(set) var web: WKWebView!
    private var ponte: Ponte!

    static let corMadeira = UIColor(red: 0x3B / 255.0, green: 0x24 / 255.0, blue: 0x14 / 255.0, alpha: 1)

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = TelaPrincipal.corMadeira

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.allowsInlineMediaPlayback = true
        cfg.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        cfg.userContentController.addUserScript(WKUserScript(source: TelaPrincipal.scriptPonte,
                                                             injectionTime: .atDocumentStart,
                                                             forMainFrameOnly: true))
        web = WKWebView(frame: .zero, configuration: cfg)
        web.uiDelegate = self
        web.navigationDelegate = self
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0xF3 / 255.0, green: 0xF0 / 255.0, blue: 0xEB / 255.0, alpha: 1)
        web.scrollView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 16.4, *) { web.isInspectable = true }
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        ponte = Ponte(tela: self)
        if let pasta = Bundle.main.url(forResource: "www", withExtension: nil) {
            web.loadFileURL(pasta.appendingPathComponent("index.html"), allowingReadAccessTo: pasta)
        }
    }

    func js(_ codigo: String) {
        DispatchQueue.main.async { [weak self] in self?.web?.evaluateJavaScript(codigo, completionHandler: nil) }
    }

    // MARK: diálogos do JavaScript

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        if prompt.hasPrefix("MM:") {
            completionHandler(ponte.executar(String(prompt.dropFirst(3))))
            return
        }
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        present(a, animated: true)
    }

    // Links externos (QR, GitHub) abrem no Safari.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, url.scheme == "https" || url.scheme == "http",
           action.navigationType == .linkActivated {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    static let scriptPonte = """
    (function(){
      function chamar(m, args){
        var r = prompt('MM:' + JSON.stringify({m: m, a: Array.prototype.slice.call(args)}));
        return r == null ? '' : r;
      }
      var nomes = ['compartilhar','tirarFoto','escolherFoto','iniciarAudio','finalizarAudio','tocarAudio',
        'pararReproducao','miniatura','lerMidiaBase64','apagarMidia','rede','versao','bleBuscar','bleBaixar','bleIdentificar','bleAoVivo','bleParar','historico','exportarHistorico',
        'bleCancelar','lotesPendentes','lerLote','apagarLote'];
      var A = {};
      nomes.forEach(function(n){ A[n] = function(){ return chamar(n, arguments); }; });
      window.Android = A;
      window.MM_IOS = true;
    })();
    """
}
