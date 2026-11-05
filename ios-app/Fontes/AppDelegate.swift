import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Rede.compartilhada.iniciar()
        let janela = UIWindow(frame: UIScreen.main.bounds)
        janela.rootViewController = TelaPrincipal()
        janela.makeKeyAndVisible()
        window = janela
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        (window?.rootViewController as? TelaPrincipal)?.js("window.aoVoltarAoApp && window.aoVoltarAoApp()")
    }
}
