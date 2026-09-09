//
//  ViewExtensions.swift
//  Moonlight for macOS
//
//  Created by Michael Kenny on 17/1/2024.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI

extension View {
    @ViewBuilder func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
    
    @ViewBuilder func availableMonospacedDigit() -> some View {
        self.monospacedDigit()
        
    }
    
    @ViewBuilder func adaptiveForegroundColor(_ color: Color) -> some View {
        self.foregroundStyle(color)
        
    }
}
