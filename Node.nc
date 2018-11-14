/*
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */
#include <Timer.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/socket.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"

module Node{
   uses interface Boot;

   uses interface SplitControl as AMControl;
   uses interface Receive;

   uses interface SimpleSend as Sender;

   uses interface CommandHandler;

   //LISTS
   uses interface List<neighbor> as nList; //P1
   uses interface List<neighbor> as nRefresher; //P1
   uses interface List<pack> as prevPacks; //P1
   uses interface List<route> as routeTable; //P2
   uses interface List<route> as forwardTable; //P2
   uses interface List<socket_store_t> as sockets; //P3

   //TIMERS
   uses interface Timer<TMilli> as ntimer; //P1
   uses interface Timer<TMilli> as rtimer; //P2
   uses interface Timer<TMilli> as TCPtimer; //P3
}

implementation{
   pack sendPackage;
   uint16_t currentSeq = 0;


   uint16_t nextPort = 0;
   

   // Prototypes
   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);

   void exclusiveBroadcast(uint16_t exception);

   void smartPing();

   event void Boot.booted(){
      call AMControl.start();
      socketBoot();
      call ntimer.startPeriodic(200000);
      call rtimer.startPeriodic(200000);
      dbg(GENERAL_CHANNEL, "Booted\n");
   }

   event void AMControl.startDone(error_t err){
      if(err == SUCCESS){
         dbg(GENERAL_CHANNEL, "Radio On\n");
      }else{
         //Retry until successful
         call AMControl.start();
      }
   }

   event void AMControl.stopDone(error_t err){}

   event void ntimer.fired(){ //NEIGHBOR REFRESH TIMER
   		//INITIALIZE VARS
   		bool found;
   		bool empty;
   		neighbor n;
   		neighbor nr;
   		neighbor* np;
   		uint16_t i;
   		uint16_t j;
   		uint16_t nsize;
   		uint16_t nrsize;
  		nsize = call nList.size();
  		nrsize = call nRefresher.size();

  		//NEIGHBOR REFRESH PROCCESS
   		//dbg(GENERAL_CHANNEL, "refreshing nList %d. . . ", TOS_NODE_ID);

   		for(i = 0; i < nsize; i++){ //reduce TTL for all neighbors 
   			np = call nList.getAddr(i);
   			np->TTL--;
   		}

   		//compare refresh table with neighbor table to make additions and refreshes
		empty = call nRefresher.isEmpty();
   		while(!empty){
   			nr = call nRefresher.popfront(); //this implimentation also wipes the refresher list.
   			found = FALSE;

   			for(j = 0; j < nsize; j++){
   				np = call nList.getAddr(j);
   				if(np->id == nr.id){ //The neighbor was already in the neighborList
   					np->TTL = NEIGHBOR_LIFESPAN; //refresh the neighbors TTL
   					found = TRUE; //flag neighbor as found
   					j = nsize; //cancel the loop
   				}
   			}

   			if(found == FALSE){ //if the neighbor wasn't already in the nList
   				nr.TTL = NEIGHBOR_LIFESPAN;
   				call nList.pushfront(nr); //now it is
   			}

   			empty = call nRefresher.isEmpty();
   		}

   		for(i = 0; i < nsize; i++){ //wipe lost neighbors from the nList
   			n = call nList.popfront(); //pull n from front
   			if(n.TTL > 0){ //if n isn't dead
   				call nList.pushback(n); //push n to the back
   			}
   		}

   		//send neighbor refresh packet
   		makePack(&sendPackage, TOS_NODE_ID, TOS_NODE_ID, MAX_TTL, 6, currentSeq, "neighbor command", PACKET_MAX_PAYLOAD_SIZE);
   		call Sender.send(sendPackage, AM_BROADCAST_ADDR); //request neighbors for the new list
   		currentSeq++;
   }

   event void rtimer.fired(){
   		bool found;
   		bool empty;
   		neighbor n;
   		route r;
   		route* rp;
   		uint16_t id;
   		uint16_t i;
   		uint16_t j;
   		uint16_t fsize;
   		uint16_t nsize;
   		uint16_t rsize;
  		nsize = call nList.size();
		fsize = call forwardTable.size();
		rsize = call routeTable.size();

   		//ROUTE CHECKING
   		for(i = 0; i < nsize; i++){ //nested for loops for addition handling
   			n = call nList.get(i);
   			found = FALSE;
   			for(j = 0; j < fsize; j++){ //checking for existence within the forwarding table
   				//dbg(GENERAL_CHANNEL, "route pre-pull\n");
   				r = call forwardTable.get(j);
   				if(r.dest == n.id){
   					found = TRUE; //the entry exists
   					j = fsize;
   				}
   			}
   			if(found == FALSE){ //if the entry doesn't exist
   				r.dest = n.id;
   				r.next = n.id;
   				r.cost = 1;
   				call forwardTable.pushback(r);
   				call routeTable.pushback(r);
   				fsize = call forwardTable.size();

   				makePack(&sendPackage, TOS_NODE_ID, n.id, 1, PROTOCOL_ROUTEUPDATE, currentSeq, "route update", PACKET_MAX_PAYLOAD_SIZE);
   				exclusiveBroadcast(n.id);
   				currentSeq++;
   			}
   		}

   		for(i = 0; i < fsize; i++){ //nested for loops for elimination handling
   			r = call forwardTable.popfront();
   			found = FALSE;
   			for(j = 0; j < nsize; j++){ //checking for existence within the neighbor list
   				n = call nList.get(j);
   				if(r.next == n.id && r.dest == n.id){
   					found = TRUE; //the entry exists
   					call forwardTable.pushback(r); //re-add the route to the forwarding table
   					j = nsize;
   				}
   			}
   			if(found == FALSE){ //if the entry doesn't exist then the neighbor is dead
   				r.cost = INFINITE_COST;
   				id = r.dest;
   				//dbg(GENERAL_CHANNEL, "node %d has died\n", id);

   				for(j = 0; j < rsize; j++){
   					rp = call routeTable.getAddr(j);
   					if(rp->next == id){
   						rp->cost = INFINITE_COST;
   						makePack(&sendPackage, TOS_NODE_ID, rp->dest, INFINITE_COST, PROTOCOL_ROUTEUPDATE, currentSeq, "route update", PACKET_MAX_PAYLOAD_SIZE);
   						exclusiveBroadcast(id);
   						currentSeq++;
   					}
   				}
   			}
   		}
   }



   event void TCPtimer.fired(){//PROJECT 3// use this in set up functions -> call TCPtimer.startPeriodic(30000);
   		//when fired this should read all incoming data from sockets and clear the buffers
   		uint8_t i;
   		socket_store_t* sock;
   		uint16_t size = call sockets.maxSize();

   		for(i = 0; i < size; i++){
   			sock = call sockets.getAddr(i);
   			if(sock->state == LISTENING){}

   			if(sock->state == ESTABLISHED){}

   			if(sock-state == CLOSED){}


   		}



   } 



   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len){
      if(len==sizeof(pack)){
         pack* myMsg=(pack*) payload;
         //dbg(GENERAL_CHANNEL, "Packet Received, Protocol: %d\n", myMsg->protocol);
		

		//PROTOCOL FOR NEIGHBOR DISCOVERY
		if(myMsg->protocol == PROTOCOL_NEIGHBORPING){ //packet recieved from a node running discovery
			//dbg(NEIGHBOR_CHANNEL, "%d -> %d", myMsg->dest, TOS_NODE_ID); //log the path of recieving packet
			makePack(&sendPackage, TOS_NODE_ID, myMsg->dest, myMsg->TTL-1, PROTOCOL_NEGHBORREPLY, myMsg->seq, myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
			call Sender.send(sendPackage, myMsg->dest);
			return msg;
		}
		if(myMsg->protocol == PROTOCOL_NEGHBORREPLY){ //packet is a neighbor reply
			if(myMsg->dest == TOS_NODE_ID){ //packet has returned to dest
				neighbor n;
				n.id = myMsg->src; //UPDATE THE NEIGHBOR LIST
				n.TTL = NEIGHBOR_LIFESPAN;
				call nRefresher.pushfront(n);

				//dbg(NEIGHBOR_CHANNEL, "Neighbor List %d Updated \n", TOS_NODE_ID);
				return msg;
			}
			return msg;
		}

		//PROTOCOL FOR ROUTING TABLE UPDATES
		if(myMsg->protocol == PROTOCOL_ROUTEUPDATE){ //PROTOCOL FOR RECIEVING A ROUTE UPDATE
			route r;
			route* rp;
			bool found = FALSE;
			uint16_t i;
			uint16_t size;
			size = call routeTable.size();

			//dbg(ROUTING_CHANNEL, "route update recived\n");
			if(myMsg->dest == TOS_NODE_ID){ //if this is a path to me then don't forward it.
				return msg;
			}

			for(i = 0; i < size; i++){
				rp = call routeTable.getAddr(i); 
				if(myMsg->dest == rp->dest){ //if the route is already established
					found = TRUE;
					if(myMsg->src == rp->next){ //if this is my current preffered route
						if(myMsg->TTL == INFINITE_COST) //if the path is broken
						{
							//set my path to broken and tell my neighbors
							//rp->next = NULL; 
							rp->cost = INFINITE_COST;
						}
						else{ //if the path isn't broken
							//update the route table and my neighbors
							rp->cost = myMsg->TTL;
							rp->cost += 1;
						}
						makePack(&sendPackage, TOS_NODE_ID, rp->dest, rp->cost, PROTOCOL_ROUTEUPDATE, currentSeq, "route update", PACKET_MAX_PAYLOAD_SIZE);
						exclusiveBroadcast(myMsg->src);
						currentSeq++;
						return msg;
					}
					else{ //if this is not my preffered route
						if(myMsg->TTL == INFINITE_COST)//If their path is broken
						{
							if(rp->cost == INFINITE_COST){ //if mine is broken
								return msg; //give up lmao
							}
							makePack(&sendPackage, TOS_NODE_ID, rp->dest, rp->cost, PROTOCOL_ROUTEUPDATE, currentSeq, "route update", PACKET_MAX_PAYLOAD_SIZE);
							//call Sender.send(sendPackage, myMsg->src);
							//currentSeq++;
							return msg;
						}
						if(rp->cost == INFINITE_COST){ //if my path is broken
							//change the route and tell my neighbors
							rp->next = myMsg->src;
							rp->cost = myMsg->TTL;
							rp->cost += 1;
							makePack(&sendPackage, TOS_NODE_ID, rp->dest, rp->cost, PROTOCOL_ROUTEUPDATE, currentSeq, "route update", PACKET_MAX_PAYLOAD_SIZE);
							exclusiveBroadcast(myMsg->src);
							currentSeq++;
							return msg;
						}
						if(myMsg->TTL+1 < rp->cost){ //if the new path is more efficient
							//dbg(GENERAL_CHANNEL, "new path found, old cost: %d, new cost: %d\n", rp->cost, myMsg->TTL);
							//change the route and tell my neighbors
							rp->next = myMsg->src;
							rp->cost = myMsg->TTL;
							rp->cost += 1;
							makePack(&sendPackage, TOS_NODE_ID, rp->dest, rp->cost, PROTOCOL_ROUTEUPDATE, currentSeq, "route update", PACKET_MAX_PAYLOAD_SIZE);
							exclusiveBroadcast(myMsg->src);
							currentSeq++;
							return msg;
						}
					}
				}
			}
			if(!found){
				//make a new route here
				r.dest = myMsg->dest;
				r.next = myMsg->src;
				r.cost = myMsg->TTL;
				r.cost += 1;
				call routeTable.pushfront(r); //add it to the route table
				makePack(&sendPackage, TOS_NODE_ID, r.dest, r.cost, PROTOCOL_ROUTEUPDATE, currentSeq, "route update", PACKET_MAX_PAYLOAD_SIZE);
				exclusiveBroadcast(myMsg->src); //forward it to neighbors
				currentSeq++;
				//dbg(ROUTING_CHANNEL, "new route broadcasted\n");
			}
			return msg;
		}


		//PROTOCOL FOR TCP PACKETS
		if(myMsg->protocol = PROTOCOL_TCP){



			//IMPLIMENT THIS FOR PROJECT 3

			/*
			*	When Transmitting an ACK packet:
			*	Make the SEQ of the ACK pack be the SEQ of the recieved pack + 1
			*	"This is the next packet I expect from you."
			*
			*	Consider making a TCPLayer.nc File
			*/

		}

		
		//PROTOCOL FOR NORMAL PING
		if(myMsg->dest == TOS_NODE_ID){ //Checks to see if the current node is the destination of the packet
			//protocol = ping
			if(myMsg->protocol == PROTOCOL_PING) {
				dbg(FLOODING_CHANNEL, "Packet has reached the destination: %d.\n", TOS_NODE_ID);	
				dbg(GENERAL_CHANNEL, "Package Payload: %s\n", myMsg->payload); //Submit the payload to the general channel
				makePack(&sendPackage, TOS_NODE_ID, myMsg->src, MAX_TTL, PROTOCOL_PINGREPLY, currentSeq, "Thanks! <3", PACKET_MAX_PAYLOAD_SIZE);
				smartPing(); //ping neighboring nodes
				currentSeq++;
				return msg;
			}
			//protocol = ping reply
			else if(myMsg->protocol == PROTOCOL_PINGREPLY){
				dbg(FLOODING_CHANNEL, "Ping reply recieved! \n");
				dbg(GENERAL_CHANNEL, "Payload: %s \n", myMsg->payload);
				return msg;
			}
			return msg;
		}
		else if(myMsg->src == TOS_NODE_ID){ //Checks to see if the current node is the source node of the packet
			//dbg(FLOODING_CHANNEL, "Packet has returned to the source: remaining TTL = %d\n", myMsg->TTL);
			return msg;
		}
		else{ //The Packet is transferable
			uint16_t i; //CHECK IF IT EXISTS IN THE PREVPACKS LIST
			uint16_t size = call prevPacks.size();
			pack prev;
			for(i=0; i<size; i++){
				prev = call prevPacks.get(i);
				if(myMsg->src == prev.src && myMsg->seq == prev.seq){
					return msg;
				}
			}
			if(myMsg->TTL > 0){ //Checks the packets remaining pings
				makePack(&sendPackage, myMsg->src, myMsg->dest, myMsg->TTL-1, myMsg->protocol, myMsg->seq, myMsg->payload, PACKET_MAX_PAYLOAD_SIZE); //Copy the packet to the send pointer
				smartPing(); //ping neighboring nodes
				call prevPacks.pushfront(sendPackage);
				//dbg(FLOODING_CHANNEL, "Packet forwarded, TTL = %d\n", myMsg->TTL); //Unneccesary but useful debugging output
				return msg;
			}
			else{ //Packet Death has occured
				//dbg(FLOODING_CHANNEL, "Packet death at node %d\n", TOS_NODE_ID);
				return msg;
			}
		}
         dbg(GENERAL_CHANNEL, "You should not be seeing this.");
         return msg;
      }
      dbg(GENERAL_CHANNEL, "Unknown Packet Type %d\n", len);
      return msg;
   }


   event void CommandHandler.ping(uint16_t destination, uint8_t *payload){
   	  dbg(GENERAL_CHANNEL, "PING EVENT \n");
   	  makePack(&sendPackage, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_PING, currentSeq, payload, PACKET_MAX_PAYLOAD_SIZE);
   	  smartPing();
   	  currentSeq++;
   	  
   }

   event void CommandHandler.printNeighbors(){
   		uint16_t  i;
   		neighbor n; //initialize the variables before loop
   		uint16_t size = call nList.size();
   		dbg(NEIGHBOR_CHANNEL, "Neighbors of %d include: \n", TOS_NODE_ID);
   		
   		for (i=0; i< size; i++)
   		{
   				n = call nList.get(i);
   				dbg(NEIGHBOR_CHANNEL,  "%d \n", n.id); //output the ID of the neighbor node
   		}
   	}

   event void CommandHandler.printRouteTable(){
   		uint16_t  i;
   		route r; //initialize the variables before loop
   		uint16_t size = call routeTable.size();
   		dbg(ROUTING_CHANNEL, "Routes of node %d include: \n", TOS_NODE_ID);
   		for (i=0; i< size; i++)
   		{
   			r = call routeTable.get(i);
   			if(r.cost == INFINITE_COST){ //if cost is infinite print it
   				dbg(ROUTING_CHANNEL,  "dest: %d, next: %d, cost: infinity \n", r.dest, r.next);
   			}
   			else{
   				dbg(ROUTING_CHANNEL,  "dest: %d, next: %d, cost: %d \n", r.dest, r.next, r.cost); //output the ID of the neighbor node
   			}
   		}
   }

   event void CommandHandler.printLinkState(){}

   event void CommandHandler.printDistanceVector(){}

   // PROJECT 3
   //set up a server at this node to recieve data from a client node
   event void CommandHandler.setTestServer(uint8_t port){
   		//Self = Server
   		//set up inbound timer here
   		//socket
   		socket_store_t* sock;
   		uint8_t sock_index = get_available_socket(); //get the index of an available socket
   		
   		sock = sockets.getAddr(sock_index); //Socket has been aquired

   		sock->src = port; //Assign the socket to the provided port value

   		call TCPtimer.startPeriodic(30000); //start TCP timer





   }


   // PROJECT 3
   //Establish a connection with a server node and transmit arbitrary bytes of data
   event void CommandHandler.setTestClient(uint16_t dest, uint8_t srcPort, uint8_t destPort, uint16_t num){
		//Self = Client
		//num = the nuber of bytes being transmitted
		//set up outbound timer here

		socket_store_t* sock;
   		uint8_t sock_index = get_available_socket(); //get the index of an available socket
   		sock = sockets.getAddr(sock_index); //Socket has been aquired

   		sock->src = srcPort; //Assign the socket to the provided port value
   		sock->dest.port = destPort;
   		sock->dest.addr = dest;
   		sock->transferSize = num;
   		sock->totalSent = 0;

   		makepack(&sendPackage, TOS_NODE_ID, dest, MAX_TTL, PROTOCOL_TCP, currentSeq, SYN, MAX_PAYLOAD_SIZE);
   		smartPing();
   		currentSeq++;


   		call TCPtimer.startPeriodic(30000); //start TCP timer





   } 

   event void CommandHandler.setAppServer(){}

   event void CommandHandler.setAppClient(){}


   // PROJECT 3
   //Close a connection to a server node
   event void CommandHandler.closeConnection(uint16_t dest, uint8_t srcPort, uint8_t destPort){
   		//self = Client

   }

   void handleNeighborDeath(uint16_t index){

   }

   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length){
      Package->src = src;
      Package->dest = dest;
      Package->TTL = TTL;
      Package->seq = seq;
      Package->protocol = protocol;
      memcpy(Package->payload, payload, length);
   }

   void exclusiveBroadcast(uint16_t exception){ //broadcasts to all neighbors except the exception
   		uint16_t i;
   		uint16_t size;
   		neighbor n;
   		size = call nList.size();
   		for(i = 0; i < size; i++){
   			n = call nList.get(i);
   			if(n.id != exception){
   				call Sender.send(sendPackage, n.id);
   			}
   		}
   }

   void smartPing(){ //Pings the current sendPackage using DVR table
   		int rsize;
   	  	int i;
   	 	bool found;
   		route r;

   	  	if(call routeTable.isEmpty()){ //If there is no routing table
      		call Sender.send(sendPackage, AM_BROADCAST_ADDR); //Send the packet to all neighbors
      		return;
   	  	}
   	 	else{
   	    	rsize = call routeTable.size();
   	    	found = FALSE;

   	    	for(i = 0; i < rsize; i++){ //Search DVR table
        		r = call routeTable.get(i);
   	  			if(sendPackage.dest == r.dest){ //If matching route is found
   	  				found == TRUE;
   	  				if(r.cost == INFINITE_COST){ //If node is dead throw an error 
   	  					dbg(GENERAL_CHANNEL, "Node %d: Disconnected - Packet Dropped\n", r.dest);
   	  					return;
   	  				}
   	  				call Sender.send(sendPackage, r.next);
   					return;
   	  			}
   	   		}
   	   		if(!found){
   	   			call Sender.send(sendPackage, AM_BROADCAST_ADDR); //Flood!
   	   			return;
   	   		}
   	  	}
   }

   void socketBoot(){ //initializes all sockets to CLOSED durring Boot
   		uint8_t i = 0;
   		socket_store_t* sock;
   		uint16_t size = call sockets.maxSize();
   		for(i = 0; i < size; i++)
   		{
   			sock = call sockets.getAddr(i);
   			sock.state = CLOSED;
   		}
   }

   uint8_t get_available_socket(){ //returns the index of the first available (closed) socket
   		uint8_t i = 0;
   		socket_store_t sock;
   		uint16_t size = call sockets.maxSize(); //look through every socket
   		for(i = 0; i < size; i++)
   		{
   			sock = call sockets.get(i);
   			if(sock.state == CLOSED){ //the first available socket index gets returned
   				return i;
   			}
   		}
   }


   //LIST FUNCTIONS




}
