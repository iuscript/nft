// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ERC20Like {
    function transfer(address, uint256) external returns (bool);
    function transferFrom( address, address, uint256) external returns (bool);
}

interface ERC721Like {
    function transferFrom( address from, address to, uint256 tokenId) external;
}

contract Owned {
    address public owner;
    address public newOwner;

    event OwnershipTransferred(address indexed _from, address indexed _to);

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner {
        require(msg.sender == owner,"you are not the owner");
        _;
    }

    function transferOwnership(address _newOwner) public onlyOwner {
        newOwner = _newOwner;
    }

    function acceptOwnership() public {
        require(msg.sender == newOwner,"you are not the owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
        newOwner = address(0);
    }
}

contract NftMarket is Owned {
    address public nftAsset;

    struct Offer {
        bool isForSale;
        uint256 tokenID;
        address seller;
        bool isBid;
        uint256 minValue;
        uint256 endTime;
        address paymentToken;
    }

    struct Bid {
        uint256 tokenID;
        address bidder;
        uint256 value;
    }

    string  public constant version  = "1.1.0";
    
    mapping(uint256 => Offer) public nftOfferedForSale;
    mapping(uint256 => Bid) public nftBids;
    mapping(address => uint256) public pendingWithdrawals;

    event Offered(uint indexed tokenID, uint256 minValue, address paymentToken);
    event BidEntered(uint256 indexed tokenID, address indexed fromAddress, uint256 value);
    event Bought(address indexed fromAddress, address indexed toAddress, uint256 indexed tokenID, uint256 value, address paymentToken);
    event NoLongerForSale(uint256 indexed tokenID);
    event Withdraw(address indexed who, uint256 value);
    event AuctionPass(uint256 indexed tokenID, uint256 timestamp);

    constructor(address _nftAsset) {
        nftAsset = _nftAsset;
    }

    function sell(uint256 tokenID, bool isBid, uint256 minSalePrice, uint256 endTime, address paymentToken) external {
        require(endTime <= block.timestamp + 30 days);
        require(endTime > block.timestamp + 5 minutes);
        ERC721Like(nftAsset).transferFrom(msg.sender, address(this), tokenID);
        nftOfferedForSale[tokenID] = Offer(true, tokenID, msg.sender, isBid, minSalePrice, endTime, paymentToken);
        emit Offered(tokenID, minSalePrice, paymentToken);
    }

    function noLongerForSale(uint256 tokenID) external {
        Offer memory offer = nftOfferedForSale[tokenID];
        require(offer.isForSale, "nft not actually for sale");
        require(msg.sender == offer.seller, "Only the seller can operate");
        require(!offer.isBid, "The auction cannot be cancelled");

        ERC721Like(nftAsset).transferFrom(address(this), offer.seller, tokenID);
        delete nftOfferedForSale[tokenID];
        emit NoLongerForSale(tokenID);
    }

    function buy(uint256 tokenID) external payable {
        Offer memory offer = nftOfferedForSale[tokenID];
        require(offer.isForSale, "nft not actually for sale");
        require(!offer.isBid, "nft is auction mode");

        if (offer.paymentToken != address(0)) {
            ERC20Like(offer.paymentToken).transferFrom(msg.sender, address(this), offer.minValue);
            ERC20Like(offer.paymentToken).transfer(offer.seller, offer.minValue);
        } else {
            require(msg.value >= offer.minValue, "Sorry, your credit is running low");
            pendingWithdrawals[offer.seller] += offer.minValue;
        }
        ERC721Like(nftAsset).transferFrom(address(this), msg.sender, tokenID);
        emit Bought(offer.seller, msg.sender, tokenID, offer.minValue, offer.paymentToken);
        delete nftOfferedForSale[tokenID];
    }

    function withdraw() external {
        uint256 amount = pendingWithdrawals[msg.sender];
        pendingWithdrawals[msg.sender] = 0;
        payable(msg.sender).transfer(amount);
        emit Withdraw(msg.sender, amount);
    }

    function enterBidForNft(uint256 tokenID, uint256 amount) public payable {
        Offer memory offer = nftOfferedForSale[tokenID];
        require(offer.isForSale, "nft not actually for sale");
        require(offer.isBid, "nft must beauction mode");
        require(block.timestamp < offer.endTime, "The auction is over");

        Bid memory bid = nftBids[tokenID];
        if (offer.paymentToken != address(0)) {
            require(amount >= offer.minValue, "The bid cannot be lower than the starting price");
            require(amount > bid.value, "This quotation is less than the current quotation");
            if (bid.value > 0) {
                ERC20Like(offer.paymentToken).transfer(bid.bidder, bid.value);
            }
            ERC20Like(offer.paymentToken).transferFrom(msg.sender, address(this), amount);
            nftBids[tokenID] = Bid(tokenID, msg.sender, amount);
            emit BidEntered(tokenID, msg.sender, amount);
        } else {
            require(msg.value >= offer.minValue, "The bid cannot be lower than the starting price");
            require(msg.value > bid.value,  "This quotation is less than the current quotation");
            if (bid.value > 0) {
                pendingWithdrawals[bid.bidder] += bid.value;
            }
            nftBids[tokenID] = Bid(tokenID, msg.sender, msg.value);
            emit BidEntered(tokenID, msg.sender, msg.value);
        }
    }

    // 拍卖结束后，交易双方完成提现处理。通常由买家调用本方法
    function deal(uint256 tokenID) external {
        Offer memory offer = nftOfferedForSale[tokenID];
        require(offer.isForSale, "nft not actually for sale");
        require(offer.isBid, "nft must beauction mode");
        require(offer.endTime < block.timestamp, "The auction is not over yet");

        Bid memory bid = nftBids[tokenID];

        if (bid.value >= offer.minValue) { // bid.value > 0 即可，上面代码保证了出价必须高于 offer.minValue
            if (offer.paymentToken == address(0)) {
                pendingWithdrawals[offer.seller] += bid.value;
            } else {
                ERC20Like(offer.paymentToken).transfer(offer.seller, bid.value);
            }
            ERC721Like(nftAsset).transferFrom(address(this), bid.bidder, tokenID);
            emit Bought(offer.seller, bid.bidder, tokenID, bid.value, offer.paymentToken);
        } else { // 没人出价，导致流拍
            ERC721Like(nftAsset).transferFrom(address(this), offer.seller, tokenID);
            emit AuctionPass(tokenID, block.timestamp);
        }
        delete nftOfferedForSale[tokenID];
        delete nftBids[tokenID];
    }

    function recoveryEth(uint256 amount) external onlyOwner {
        payable(owner).transfer(amount);
    }

    receive() external payable {}
}
