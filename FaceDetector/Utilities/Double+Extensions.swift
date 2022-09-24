//
//  Double+Extensions.swift
//  FaceDetector
//
//  Created by Heitor Novais on 24/09/22.
//

import Foundation
import UIKit

extension CGFloat {

    func rounded(toPlaces places:Int) -> CGFloat {
        let divisor = pow(10.0, CGFloat(places))
        return (self * divisor).rounded() / divisor
    }
}
