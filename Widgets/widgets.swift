//
//  widgets.swift
//  Status
//

import SwiftUI
import WidgetKit

import CPU
import GPU
import RAM
import Disk
import Net

@main
struct WidgetsBundle: WidgetBundle {
    var body: some Widget {
        CPUWidget()
        GPUWidget()
        RAMWidget()
        DiskWidget()
        NetworkWidget()
        UnitedWidget()
        HealthWidget()
    }
}
