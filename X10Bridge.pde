//
//  X10Bridge
//
// BSD License
// Copyright (c) 2010, Dan Kacenjar
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
//
// * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
// * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
// * Neither the name X10Bridge nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, 
// INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE 
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, 
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; 
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN 
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS 
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#include <x10.h>
#include <x10constants.h>

#include <Ethernet.h>
#include <string.h>

#define RPT_SEND 1
// Make sure to replace with your API Key and Feed ID
#define PACHUBE_API_KEY "Your API Key"
#define PACHUBE_FEED_ID 504

#define CARRIAGE_RETURN '\r'
#define NEW_LINE '\n'

#define BUFFER_LENGTH 200

#define ZERO_CROSS_PIN 8
#define DATA_PIN 9

#define DELAY_BETWEEN_CONNECTIONS 3500

boolean waitState = false;
boolean connectState = false;
boolean readState = false;

unsigned long lastConnectTime = 0;

// Ethernet Shield Configuration - make sure to specify your parameters here
byte mac[] = { 0x00, 0x01, 0xE6, 0x72, 0x08, 0xEB }; // Unique mac address you specify
byte ip[] = { 192, 168, 1, 177 }; // ip address of ethernet shield that you specify
byte server[] = { 209, 40, 205, 190 }; // Pachube
Client client(server, 80);

// Pachube Data feed parsing variables
char newModifiedDateTime[50];
char currentModifiedDateTime[50];
char bufferData[BUFFER_LENGTH + 1];
int bufferDataCount = 0;
int dataLength = 0;
char currChar;
char priorChar;
boolean isCommandData = false;
boolean doneReadingData = false;

// X10 control variables
char houseCode;
int keyCode;
int onOffStatus;
x10 myHouse = x10(ZERO_CROSS_PIN, DATA_PIN);

// Setup Wait State
void enterWaitState() {
  lastConnectTime = millis();
  waitState = true;
  connectState = false;
  readState = false;
}

// Setup Connecting state
// Here we connect to Pachube data service
void enterConnectState() {
  waitState = false;
  connectState = true;
  readState = false;
}

// Setup Read State
// Here we are reading data received from Pachube
void enterReadState() {
  waitState = false;
  connectState = false;
  readState = true;
}

boolean isWaitState() {
  return waitState;
}

// Helper function to query connect state
boolean isConnectState() {
  return connectState;
}

// Helper function to query read state
boolean isReadState() {
  return readState;
}

// Connect to Pachube
void establishConnectionToPachube() {
  
  if (client.connect()) {
    client.print("GET /api/");
    client.print(PACHUBE_FEED_ID);
    client.println(".csv HTTP/1.1");
    client.println("Host: www.pachube.com");
    client.print("X-PachubeApiKey: ");
    client.println(PACHUBE_API_KEY);
    client.println("User-Agent: AVR Ethernet");
    client.println("Accept: text/html");
    client.println();
    enterReadState();
  } else {
    Serial.println("connection failed");
    enterWaitState();
  }
}

// Determine if wait interval has elapsed
void checkConnectionInterval() {
  if ((millis() - lastConnectTime) > DELAY_BETWEEN_CONNECTIONS) {
    enterConnectState();
  }
}

void resetBufferData() {
  bufferDataCount = 0;
  memset(bufferData, 0, sizeof(bufferData));
}

void resetModifiedDateTimeBuffer() {
  memset(newModifiedDateTime, 0, sizeof(newModifiedDateTime));
}

// Looks at "Last-Modified:" header to determine if a new X10 command has been sent.
boolean isNewX10Command() {
  if (strcmp(newModifiedDateTime, currentModifiedDateTime)) {
    strcpy(currentModifiedDateTime, newModifiedDateTime);
    resetModifiedDateTimeBuffer();
    return true;
  }
  return false;
}

void setup() {
  // Configure pins for X10 setup
  pinMode(ZERO_CROSS_PIN, INPUT);      // zero crossing
  digitalWrite(ZERO_CROSS_PIN, HIGH);  // set pullup resistor
 
  // Clear out data buffer
  resetBufferData();
 
  // Establish Ethernet and Serial initialization
  Ethernet.begin(mac, ip);
  Serial.begin(57600);
  
  delay(1000);
  establishConnectionToPachube();  
}

void loop() {
  
  // Put in to handle roll over of millis approximately every 50 days
  if (millis() < lastConnectTime) {
    lastConnectTime = millis();
  }
  
  if (isWaitState()) {
    checkConnectionInterval();
  }
  
  if (isConnectState()) {
    establishConnectionToPachube();
  }
  
  if (isReadState()) {

    if (client.available()) {
      currChar = client.read();
      bufferData[bufferDataCount++] = currChar;
      
      if (currChar == '\n') {
        if (strstr(bufferData, "Last-Modified:")) {
          strcpy(newModifiedDateTime, bufferData);
        } else if (strstr(bufferData, "Content-Length:")) {
          sscanf(bufferData, "Content-Length: %d", &dataLength);
        }
        
        resetBufferData();
      }
      
      
      if (isCommandData) {
        //commandData[commandDataCount++] = currChar;
        if (dataLength == bufferDataCount) {
          doneReadingData = true;
        }
      }
      
      if (currChar == '\r' && priorChar == '\n') {
        isCommandData = true;
        // discard remaining new line character
        client.read();
        resetBufferData();
      }
      
      priorChar = currChar;
    }
    
    if (doneReadingData) {
      int conversionCount = sscanf(bufferData, "%c,%d,%d", &houseCode, &keyCode, &onOffStatus);
      executeX10Command(getHouseCode(houseCode), getKeyCode(keyCode), onOffStatus);
    }
    
    if (!client.connected() || doneReadingData) {
      client.stop();
      doneReadingData = false;
      isCommandData = false;
      resetBufferData();
      enterWaitState();
    }
  }
}

byte getHouseCode(char hc) {
  byte result = 0;
  switch (hc) {
    case 'A':
      result = A;
      break;
    case 'B':
      result = B;
      break;
    case 'C':
      result = C;
      break;
    case 'D':
      result = D;
      break;
    case 'E':
      result = E;
      break;
    case 'F':
      result = F;
      break;
    case 'G':
      result = G;
      break;
    case 'H':
      result = H;
      break;
    case 'I':
      result = I;
      break;
    case 'J':
      result = J;
      break;
    case 'K':
      result = K;
      break;
    case 'L':
      result = L;
      break;
    case 'M':
      result = M;
      break;
    case 'N':
      result = N;
      break;
    case 'O':
      result = O;
      break;
    case 'P':
      result = P;
      break;
  }
  return result;
}

byte getKeyCode(int kc) {
  byte result = 0;
  switch (kc) {
    case 1:
      result = UNIT_1;
      break;
    case 2:
      result = UNIT_2;
      break;
    case 3:
      result = UNIT_3;
      break;
    case 4:
      result = UNIT_4;
      break;
    case 5:
      result = UNIT_5;
      break;
    case 6:
      result = UNIT_6;
      break;
    case 7:
      result = UNIT_7;
      break;
    case 8:
      result = UNIT_8;
      break;
    case 9:
      result = UNIT_9;
      break;
    case 10:
      result = UNIT_10;
      break;
    case 11:
      result = UNIT_11;
      break;
    case 12:
      result = UNIT_12;
      break;
    case 13:
      result = UNIT_13;
      break;
    case 14:
      result = UNIT_14;
      break;
    case 15:
      result = UNIT_15;
      break;
    case 16:
      result = UNIT_16;
      break;
  }
  return result;
}

void executeX10Command(byte hc, byte kc, int onOffStatus) {
  if (isNewX10Command()) {
    myHouse.write(hc, kc, RPT_SEND);
    if (onOffStatus) {
      myHouse.write(hc, ON, RPT_SEND);
    } else {
      myHouse.write(hc, OFF, RPT_SEND);
    }
  }
}

