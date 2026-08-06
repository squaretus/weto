import Foundation
import WetoCore
import UpdateKitHelper

// Привилегированный демон: скачивает и устанавливает обновление под root.
// Вся логика — в UpdateKitHelper; здесь только конфигурация этого приложения.
//
// Ссылки глобальные не случайно: delegate у NSXPCListener слабый, и без
// сильной ссылки release-сборка освободила бы его сразу после resume().
private let service = UpdaterHelperService(configuration: WetoUpdate.configuration)
private let listener = NSXPCListener(
    machServiceName: WetoUpdate.configuration.machServiceName
)

listener.delegate = service
listener.resume()
service.logStart()
dispatchMain()
