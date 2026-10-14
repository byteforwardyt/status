//
//  protocol.swift
//  Status
//

import Foundation

@objc public protocol HelperProtocol {
    func version(completion: @escaping (String) -> Void)
    func setSMCPath(_ path: String)
    
    func setFanMode(id: Int, mode: Int, completion: @escaping (String?) -> Void)
    func setFanSpeed(id: Int, value: Int, completion: @escaping (String?) -> Void)
    func resetFanControl(completion: @escaping (String?) -> Void)
    
    func uninstall()
}
