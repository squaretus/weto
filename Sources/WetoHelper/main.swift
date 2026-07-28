import Foundation
import WetoXPC

// Привилегированный демон: скачивает и устанавливает обновление под root.
// Запускается launchd как Mach-сервис com.weto.helper.
//
// Ссылки глобальные не случайно: delegate у NSXPCListener слабый, и без
// сильной ссылки release-сборка освободила бы его сразу после resume().
private let delegate = HelperDelegate()
private let listener = NSXPCListener(machServiceName: WetoXPCConstants.machServiceName)

listener.delegate = delegate
listener.resume()
HelperLogger.log("слушаю \(WetoXPCConstants.machServiceName)")
dispatchMain()
