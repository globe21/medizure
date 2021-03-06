//  BluetoothManager.swift
//  Medizure

import Foundation
import CoreBluetooth

@objc(BluetoothManager)
class BluetoothManager:
  NSObject,
  CBCentralManagerDelegate,
  CBPeripheralDelegate {
  
  var centralManager: CBCentralManager!
  var deviceName: String?
  var device: CBPeripheral?
  var bridge: RCTBridge!

  var heartRate = 0
  var rMSSDcurrent: Float = 0.0
  var sensorDetected = false
  var energyExpended: Int?
  var rrIntervals = [Float]()

  // The amount of time used for rMSSD measurement
  let MEASURE_TIME_S: Float = 60.0


  func calcrMSSD(rrList: [Float]) -> Float {

    var rMSSD: Float = 0.0
    var n: Int = 0

    // ASSUME THAT INTERVALS ARE IN SECONDS -> CONVERT TO MS
    let rr = rrList.map{ $0 * 1000.0 }

    // Iterate the RR intervals
    var prev = rr.first!
    for interval in rr.suffix(rr.count - 1) {

      // Discard values that differ more than 20% from the previous value
      if (abs(prev - interval) > (prev * 0.2)) {
        continue
      }

      // Sum of squares
      rMSSD += Float((interval - prev) * (interval - prev))
      n += 1
      prev = interval
    }

    // Return the averaged and square-rooted rMSSD
    return sqrt(rMSSD / Float(n))
  }
  

  @objc(scanForDevices)
  func scanForDevices() -> Void {
    centralManager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: true])
  }
  
  @objc(stopScan)
  func stopScan() -> Void {
    centralManager.stopScan()
  }

  @objc(connectDevice:uuid:)
  func connectDevice(name: String, uuid: String) -> Void {
    NSLog("Connecting to \(name)...")
    deviceName = name
    device = centralManager.retrievePeripherals(withIdentifiers: [UUID(uuidString: uuid)!]).first
    if (device != nil) {
      device!.delegate = self
      centralManager.stopScan()
      centralManager.connect(device!, options: nil)
    }
    else {
      NSLog("Device \(name) not found!")
    }
  }

  // State updated
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    centralManager.scanForPeripherals(withServices: nil, options: nil)
  }
  
  // Peripheral discovered
  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
    NSLog("Peripheral discovered: \(peripheral.name)")
    if ((peripheral.name) != nil) {
      bridge.eventDispatcher().sendAppEvent(withName: "peripheralDiscovered", body: ["name": peripheral.name ?? "Default device", "uuid": peripheral.identifier.uuidString ])
    }
  }
  
  // Peripheral connected
  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    NSLog("**** SUCCESSFULLY CONNECTED TO \(deviceName) !")
    // Discover only heart rate services "180D"
    peripheral.discoverServices([CBUUID(string: "180D")])
  }

  // Peripheral disconnected
  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    NSLog("**** CONNECTION LOST TO \(deviceName):\(error?.localizedDescription)!")
    bridge.eventDispatcher().sendAppEvent(withName: "connectionLost", body: peripheral.name)
  }
  
  // Peripheral failed to connected
  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    NSLog("**** FAILED TO CONNECT TO \(deviceName):\(error?.localizedDescription)!")
    bridge.eventDispatcher().sendAppEvent(withName: "failedToConnect", body: peripheral.name)
  }

  // Service discovered
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    if error != nil {
      NSLog("ERROR DISCOVERING SERVICES: \(error?.localizedDescription)")
      return
    }
    NSLog("Services found")
    
    // Core Bluetooth creates an array of CBService objects —- one for each service that is discovered on the peripheral.
    if let services = peripheral.services {
      for service in services {
        NSLog("Discovered service \(service)")
        peripheral.discoverCharacteristics(nil, for: service)
      }
    }
  }


  // Characteristics discovered
  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    if error != nil {
      NSLog("ERROR DISCOVERING CHARACTERISTICS: \(error?.localizedDescription)")
      return
    }
    NSLog("Characteristics found")
    if let characteristics = service.characteristics {
      for characteristic in characteristics {
        if (characteristic.uuid == CBUUID(string: "2A37")) {
          peripheral.setNotifyValue(true, for: characteristic)
        }
      }
    }
  }
  
  
  // Characteristics value updated
  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    if error != nil {
      NSLog("ERROR ON UPDATING VALUE FOR CHARACTERISTIC: \(characteristic) - \(error?.localizedDescription)")
      return
    }
    if (characteristic.uuid == CBUUID(string: "2A37")) {
      getHeartRateMeasurementData(hrmData: characteristic.value! as NSData)
      if (rrIntervals.reduce(0,+) >= 2) {
        rMSSDcurrent = calcrMSSD(rrList: rrIntervals)
        NSLog("HRV: \(rMSSDcurrent)")
        bridge.eventDispatcher().sendAppEvent(withName: "rMSSDTick", body: rMSSDcurrent)
      }
    }
  }


  // Heart rate parsing
  private func getHeartRateMeasurementData(hrmData: NSData)
  {
    // Maintain an index into the measurement data of the next byte to read.
    var byteIndex = 0
    
    var hrmFlags: UInt8 = 0
    hrmData.getBytes(&hrmFlags, length: MemoryLayout<UInt8>.size)
    byteIndex += MemoryLayout<UInt8>.size
    
    if HeartRateMeasurement.HeartRateValueFormatUInt16.flagIsSet(flagData: hrmFlags) {
      var value: UInt16 = 0
      hrmData.getBytes(&value, range: NSMakeRange(byteIndex, MemoryLayout<UInt16>.size))
      byteIndex += MemoryLayout<UInt16>.size
      heartRate = Int(value)
    }
    else {
      var value: UInt8 = 0
      hrmData.getBytes(&value, range: NSMakeRange(byteIndex, MemoryLayout<UInt8>.size))
      byteIndex += MemoryLayout<UInt8>.size
      heartRate = Int(value)
    }
    
    if HeartRateMeasurement.SensorContactIsSupported.flagIsSet(flagData: hrmFlags) {
      sensorDetected = HeartRateMeasurement.SensorContactDetected.flagIsSet(flagData: hrmFlags)
    }
    
    if HeartRateMeasurement.EnergyExpended.flagIsSet(flagData: hrmFlags) {
      var value: UInt16 = 0
      hrmData.getBytes(&value, range: NSMakeRange(byteIndex, MemoryLayout<UInt16>.size))
      byteIndex += MemoryLayout<UInt16>.size
      energyExpended = Int(value)
    }
    
    if HeartRateMeasurement.RRInterval.flagIsSet(flagData: hrmFlags) {
      while byteIndex < hrmData.length {
        var value: UInt16 = 0
        hrmData.getBytes(&value, range: NSMakeRange(byteIndex, MemoryLayout<UInt16>.size))
        byteIndex += MemoryLayout<UInt16>.size
//        NSLog("RR interval sum: \(rrIntervals.reduce(0, +))")
        while (rrIntervals.reduce(0, +) > MEASURE_TIME_S) {
          rrIntervals.removeFirst()
        }
        rrIntervals.append(Float(value) / 1024.0)
//        bridge.eventDispatcher().sendAppEvent(withName: "rrInterval", body: ["interval": Float(value) / 1024.0])
      }
    }
    
//    NSLog("Heart rate: \(heartRate)")
//    NSLog("Sensor detected: \(sensorDetected)")
//    if let energyExpended = energyExpended {
//      NSLog("Energy expended: \(energyExpended)")
//    }
//    NSLog("RR Intervals: \(rrIntervals)")
  }

  private enum HeartRateMeasurement: UInt8 {
    case HeartRateValueFormatUInt8  = 0b00000000
    case HeartRateValueFormatUInt16 = 0b00000001
    case SensorContactIsSupported   = 0b00000100
    case SensorContactDetected      = 0b00000110
    case EnergyExpended             = 0b00001000
    case RRInterval                 = 0b00010000
    
    func flagIsSet(flagData: UInt8) -> Bool {
      return (flagData & self.rawValue) != 0
    }
  }
}
