// Copyright 2016-2017 Cisco Systems Inc
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import UIKit
import Alamofire
import MobileCoreServices.UTCoreTypes
import MobileCoreServices.UTType

class ListMessageOperation: Operation {
    var resultList : [MessageModel] = [MessageModel]()
    let authenticator: Authenticator
    var roomId: String
    var mentionedPeople: String?
    var before: Date?
    var beforeMessage: String?
    var max: Int = 50
    var remainCount: Int = 50
    var completionHandler : (ServiceResponse<[MessageModel]>) -> Void
    var queue : DispatchQueue?
    var keyMaterial : String?
    init(authenticator: Authenticator,
         roomId : String,
         mentionedPeople: String? = nil,
         before: Date? = nil,
         beforeMessage: String? = nil,
         max: Int?,
         keyMaterial: String? = nil,
         queue:DispatchQueue? = nil,
         completionHandler: @escaping (ServiceResponse<[MessageModel]>) -> Void)
    {
        self.authenticator = authenticator
        self.roomId = roomId
        self.mentionedPeople = mentionedPeople
        self.before = before
        self.beforeMessage = beforeMessage
        self.keyMaterial = keyMaterial
        self.queue = queue
        self.completionHandler = completionHandler
        if let m = max{
            self.max = m
            self.remainCount = m
        }
        super.init()
    }
    
    override func main() {
        if let beforeMessage = self.beforeMessage{
            self.getRequest(messageId: beforeMessage)
        }else{
            self.listRequest()
        }
    }
    
    private func getRequest(messageId: String){
        let request = messageServiceBuilder().path("activities")
            .method(.get)
            .path(messageId.sparkSplitString())
            .queue(queue)
            .build()
        request.responseObject { (response : ServiceResponse<MessageModel>) in
            switch response.result{
            case .success(let message):
                self.before = message.created
                self.listRequest()
                break
            case .failure(let error):
                self.returnFailureResult(error)
                break
            }
        }
    }
    
    private func listRequest(){
        if self.max == 0{
            self.returnSuccessResult()
            return
        }
        var path : String
        var query : RequestParameter
        if let _ = self.mentionedPeople{
            path = "mentions"
            query = RequestParameter([
                "conversationId": roomId.sparkSplitString(),
                "sinceDate": self.getBeforeTimeString(date: before),
                "limit": max,
                ])
        }else{
            path = "activities"
            query = RequestParameter([
                "conversationId": roomId.sparkSplitString(),
                "maxDate": self.getBeforeTimeString(date: before),
                "limit": max,
                ])
        }
        let listRequest = messageServiceBuilder().path(path)
            .keyPath("items")
            .method(.get)
            .query(query)
            .queue(self.queue)
            .build()
        
        listRequest.responseArray {(response: ServiceResponse<[MessageModel]>) in
            switch response.result{
            case .success(let list):
                if list.count == 0{
                    self.returnSuccessResult()
                }else{
                    self.processResult(list)
                }
                break
            case .failure(let error):
                self.returnFailureResult(error)
                break
            }
        }
    }
    
    private func processResult(_ list: [MessageModel]){
        let filterList = list.filter({$0.messageAction == MessageAction.post || $0.messageAction == MessageAction.share})
        self.remainCount -= filterList.count
        if self.remainCount > 0{
            self.resultList.append(contentsOf: filterList)
            self.before = list.last?.created
            self.listRequest()
        }else if self.remainCount < 0{
            let remain = self.remainCount + filterList.count
            self.resultList.append(contentsOf: filterList.prefix(upTo: remain))
            self.decryptList()
        }else{
            self.resultList.append(contentsOf: filterList)
            self.decryptList()
        }
    }
    
    // MARK: - DecrypMessageList
    private func decryptList(){
        guard let acitivityKeyMaterial = self.keyMaterial else{
            return
        }
        for message in self.resultList{
            do {
                if message.text == nil{
                    message.text = ""
                }
                guard let chiperText = message.text
                    else{
                        return;
                }
                if(chiperText != ""){
                    let plainTextData = try CjoseWrapper.content(fromCiphertext: chiperText, key: acitivityKeyMaterial)
                    let clearText = NSString(data:plainTextData ,encoding: String.Encoding.utf8.rawValue)
                    message.text = clearText! as String
                }
                if let files = message.files{
                    for file in files{
                        if let displayname = file.displayName,let scr = file.scr{
                            let nameData = try CjoseWrapper.content(fromCiphertext: displayname, key: acitivityKeyMaterial)
                            let clearName = NSString(data:nameData ,encoding: String.Encoding.utf8.rawValue)! as String
                            let srcData = try CjoseWrapper.content(fromCiphertext: scr, key: acitivityKeyMaterial)
                            let clearSrc = NSString(data:srcData ,encoding: String.Encoding.utf8.rawValue)! as String
                            if let image = file.thumb{
                                let imageSrcData = try CjoseWrapper.content(fromCiphertext: image.scr, key: acitivityKeyMaterial)
                                let imageClearSrc = NSString(data:imageSrcData ,encoding: String.Encoding.utf8.rawValue)! as String
                                image.scr = imageClearSrc
                            }
                            file.displayName = clearName
                            file.scr = clearSrc
                        }
                    }
                    message.files = files
                }
            }catch{}
        }
        self.returnSuccessResult()
    }
    
    private func getBeforeString(){
        
    }
    
    private func getBeforeTimeString(date: Date?)->String{
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        var newDate = Date()
        if let dat = date{
            newDate = dat.addingTimeInterval(-0.1)
        }
        let before = formatter.string(from: newDate)
        return before
    }
    
    //MARK: - ReturnResult
    private func returnSuccessResult(){
        let result = Result<[MessageModel]>.success(resultList)
        let serviceResponse = ServiceResponse(nil, result)
        self.completionHandler(serviceResponse)
    }
    private func returnFailureResult(_ error: Error){
        let result =  Result<[MessageModel]>.failure(error)
        let serviceResponse = ServiceResponse(nil, result)
        self.completionHandler(serviceResponse)
    }
    
    //MARK: - RequestBuilders
    private func messageServiceBuilder() -> ServiceRequest.MessageServerBuilder {
        return ServiceRequest.MessageServerBuilder(authenticator)
    }
    
}


